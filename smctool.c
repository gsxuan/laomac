// smctool.c — 极简 AppleSMC 键读写工具 (需 root 运行)
// 用法:
//   smctool read   <KEY>           读取键值 (ui8/ui16 打印十进制, 其它打印十六进制)
//   smctool write  <KEY> <VALUE>   以 ui8 写入单字节值
//   smctool faninfo                打印全部风扇: 当前/最大转速、手动模式状态
//   smctool fanset <N|RPM> <RPM>   风扇手动定速: N=风扇编号(0起), RPM=目标转速
//   smctool fanset auto            所有风扇恢复 SMC 自动调速
//
// 用于 Laomac 充电限制: BCLM(限制开关) CH0B(上限百分比) CHBI(禁止充电)
// 风扇键: FS!(模式位图) FxMd(手动开关) FxTg(目标转速,fpe2) FxAc(当前) FxMx(上限)
// 参考 smcFanControl / iStats 的经典 AppleSMC 用户态通信方式

#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} SMCVersion_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData_t;

typedef struct {
    IOByteCount dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData_t;

typedef struct {
    uint32_t key;
    SMCVersion_t vers;
    SMCPLimitData_t pLimitData;
    SMCKeyInfoData_t keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

#define KERNEL_INDEX_SMC    2
#define SMC_CMD_READ_BYTES  5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

static io_connect_t conn;

static int smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                   IOServiceMatching("AppleSMC"));
    if (!svc) {
        fprintf(stderr, "未找到 AppleSMC 服务\n");
        return 1;
    }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "IOServiceOpen 失败 (%x), 需要 root 权限\n", kr);
        return 1;
    }
    return 0;
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(*out);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC,
                                     in, sizeof(*in), out, &outSize);
}

static uint32_t str_to_key(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) |
           ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static int smc_read(uint32_t key, uint8_t *bytes, uint32_t *size) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return 1;

    *size = (uint32_t)out.keyInfo.dataSize;

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_BYTES;
    // T2 机型要求 READ_BYTES 固定请求 32 字节缓冲区, 传实际键长会失败
    in.keyInfo.dataSize = 32;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return 1;

    // 用 KEYINFO 阶段拿到的键长拷贝: READ_BYTES 响应不保证回填 keyInfo.dataSize,
    // 若用它判长会拷 0 字节, 导致调用方读到未初始化垃圾值
    memcpy(bytes, out.bytes, *size);
    return 0;
}

static int smc_write_ui8(uint32_t key, uint8_t value) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = 1;
    in.bytes[0] = value;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return 1;
    return 0;
}

// 按指定大小写入 (用于 ui16 / fpe2 等多字节键)
static int smc_write_n(uint32_t key, const uint8_t *bytes, uint32_t size) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return 1;
    return 0;
}

// fpe2: 14.2 定点数, rpm * 4 为大端 16 位
static uint16_t rpm_to_fpe2(int rpm) { return (uint16_t)(rpm << 2); }
static int fpe2_to_rpm(uint8_t hi, uint8_t lo) { return ((hi << 8) | lo) >> 2; }

// 转速键读取: 兼容 fpe2(2字节定点, 旧机型) 与 flt(4字节小端浮点, T2 机型)
// 返回 rpm, 失败返回 -1; 若 enc 非空则回传编码类型
static int read_rpm_key(const char *name, char *enc) {
    uint8_t buf[32];
    uint32_t size;
    uint32_t key = str_to_key(name);
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != kIOReturnSuccess || out.result != 0) {
        fprintf(stderr, "[dbg] %s KEYINFO kr=0x%x result=%d\n", name, kr, out.result);
        return -1;
    }
    size = out.keyInfo.dataSize;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_BYTES;
    in.keyInfo.dataSize = 32; // T2 机型要求固定 32 字节缓冲区
    kr = smc_call(&in, &out);
    if (kr != kIOReturnSuccess || out.result != 0) {
        fprintf(stderr, "[dbg] %s READ kr=0x%x result=%d\n", name, kr, out.result);
        return -1;
    }
    memcpy(buf, out.bytes, size);
    fprintf(stderr, "[dbg] %s size=%u\n", name, size);
    if (size == 2) {
        if (enc) *enc = 'f'; // fpe2
        return fpe2_to_rpm(buf[0], buf[1]);
    }
    if (size == 4) {
        if (enc) *enc = 'F'; // flt (小端)
        float f;
        memcpy(&f, buf, 4);
        if (f < 0 || f > 100000) return -1;
        return (int)f;
    }
    return -1;
}

// 转速键写入: 按读回的键宽选择编码
static int write_rpm_key(const char *name, int rpm) {
    uint32_t key = str_to_key(name);
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return 1;
    uint32_t size = out.keyInfo.dataSize;
    if (size == 2) {
        uint16_t v = rpm_to_fpe2(rpm);
        uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)(v & 0xff) };
        return smc_write_n(key, b, 2);
    }
    if (size == 4) {
        float f = (float)rpm;
        uint8_t b[4];
        memcpy(b, &f, 4); // 小端, 与 SMC flt 读取字节序一致
        return smc_write_n(key, b, 4);
    }
    return 1;
}

// MARK: 风扇信息/控制

#define MAX_FANS 4

static int cmd_faninfo(void) {
    uint8_t buf[32];
    uint32_t size;
    // FNum: 风扇数量
    int numFans = 0;
    if (smc_read(str_to_key("FNum"), buf, &size) == 0 && size >= 1) {
        numFans = buf[0];
    }
    if (numFans <= 0 || numFans > MAX_FANS) numFans = MAX_FANS;
    fprintf(stderr, "[dbg] numFans=%d (FNum read=%s)\n", numFans,
            (size >= 1) ? "ok" : "fail");
    for (int i = 0; i < numFans; i++) {
        char keyAc[5], keyMx[5], keyMd[5], keyTg[5];
        snprintf(keyAc, 5, "F%dAc", i);
        snprintf(keyMx, 5, "F%dMx", i);
        snprintf(keyMd, 5, "F%dMd", i);
        snprintf(keyTg, 5, "F%dTg", i);

        char enc = 0;
        int cur = read_rpm_key(keyAc, &enc);
        int mx = read_rpm_key(keyMx, NULL);
        int tgt = read_rpm_key(keyTg, NULL);
        fprintf(stderr, "[dbg] fan%d cur=%d mx=%d tgt=%d enc=%c\n", i, cur, mx, tgt, enc);

        uint8_t buf[32];
        uint32_t size;
        int manual = 0;
        if (smc_read(str_to_key(keyMd), buf, &size) == 0 && size >= 1)
            manual = buf[0] != 0;
        if (cur < 0 && mx < 0) continue;  // 该风扇不存在
        printf("fan%d: cur=%d max=%d manual=%d target=%d enc=%c\n",
               i, cur, mx, manual, tgt, enc ? enc : '?');
    }
    return 0;
}

// FS! 模式位图: 第 i 位 = 风扇 i 手动模式 (键宽因机型而异, 读回同宽写回)
// idx < 0 表示清零全部位
static int fs_mode_set(int idx, int on) {
    uint32_t key = str_to_key("FS!");
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return 1;
    uint32_t size = out.keyInfo.dataSize;
    if (size == 0 || size > 4) return 1;

    uint8_t buf[32];
    uint32_t rsize;
    uint32_t val = 0;
    if (smc_read(key, buf, &rsize) == 0) {
        for (uint32_t i = 0; i < rsize && i < 4; i++) val |= (uint32_t)buf[i] << (8 * (rsize - 1 - i));
    }
    if (idx < 0) {
        val = 0;
    } else if (on) {
        val |= (1u << idx);
    } else {
        val &= ~(1u << idx);
    }

    uint8_t w[4];
    for (uint32_t i = 0; i < size; i++) w[i] = (uint8_t)(val >> (8 * (size - 1 - i)));
    return smc_write_n(key, w, size);
}

static int set_fan_manual(int idx, int rpm) {
    char keyMd[5], keyTg[5], keyMx[5];
    snprintf(keyMd, 5, "F%dMd", idx);
    snprintf(keyTg, 5, "F%dTg", idx);
    snprintf(keyMx, 5, "F%dMx", idx);

    // 目标转速不得超过该风扇上限
    int mx = read_rpm_key(keyMx, NULL);
    if (mx <= 0) mx = 6000;
    if (rpm > mx) rpm = mx;

    // 顺序参考 smcFanControl: 先置 FS! 模式位(若存在), 再写 FxMd / FxTg
    fs_mode_set(idx, 1); // T2 机型无 FS! 键, 失败可忽略
    if (smc_write_ui8(str_to_key(keyMd), 1)) {
        fprintf(stderr, "写入 %s 失败\n", keyMd);
        return 4;
    }
    if (write_rpm_key(keyTg, rpm)) {
        fprintf(stderr, "写入 %s 失败\n", keyTg);
        return 4;
    }
    printf("fan%d: manual rpm=%d (max=%d)\n", idx, rpm, mx);
    return 0;
}

static int set_fan_auto(void) {
    // 所有风扇回到自动: 逐个清 FxMd, 若存在 FS! 则一并清零
    for (int i = 0; i < MAX_FANS; i++) {
        char keyMd[5];
        snprintf(keyMd, 5, "F%dMd", i);
        smc_write_ui8(str_to_key(keyMd), 0); // 不存在的风扇静默跳过
    }
    fs_mode_set(-1, 0); // T2 机型无 FS! 键, 失败可忽略
    printf("all fans: auto\n");
    return 0;
}

// MARK: 温度传感器 (参考 exelban/stats 的 SMC 键表, 兼容 sp78/flt 两种编码)

static const struct { const char *key; const char *label; } temp_table[] = {
    { "TC0D", "CPU Die" },        { "TC0E", "CPU Die (均值)" },
    { "TC0F", "CPU Die (峰值)" }, { "TC0P", "CPU 附近" },
    { "TCGC", "GPU (集成)" },     { "TG0D", "GPU Die" },
    { "TG0P", "GPU 附近" },       { "Th1H", "散热片 1" },
    { "Th2H", "散热片 2" },       { "Tm0P", "内存附近" },
    { "Ts0P", "掌托" },           { "TaLP", "出风口" },
    { "TB0T", "电池 1" },         { "TB1T", "电池 2" },
    { "TB2T", "电池 3" },         { "Tp0C", "电源模块" },
    { "Tw0P", "无线模块" },       { "TI0P", "Thunderbolt" },
};

// 温度键读取: sp78(2字节, v/256) 或 flt(4字节小端浮点), 返回 ℃, 失败 -1
static double read_temp_key(const char *name) {
    uint8_t buf[32];
    uint32_t size;
    if (smc_read(str_to_key(name), buf, &size) != 0) return -1;
    double v = -1;
    if (size == 2) {
        v = (double)((buf[0] << 8) | buf[1]) / 256.0;
    } else if (size == 4) {
        float f;
        memcpy(&f, buf, 4);
        v = f;
    }
    // 过滤无效值 (传感器不存在时通常返回 0/异常大值)
    if (v <= 0.5 || v > 130) return -1;
    return v;
}

static int cmd_temps(void) {
    int n = sizeof(temp_table) / sizeof(temp_table[0]);
    int found = 0;
    for (int i = 0; i < n; i++) {
        double t = read_temp_key(temp_table[i].key);
        if (t < 0) continue;
        printf("%s|%s|%.1f\n", temp_table[i].key, temp_table[i].label, t);
        found++;
    }
    if (found == 0) {
        fprintf(stderr, "未读到有效温度键\n");
        return 4;
    }
    return 0;
}

// MARK: 调试: 打印键读取的详细失败码

static void dbg_read(const char *name) {
    uint32_t key = str_to_key(name);
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    printf("struct_size=%zu ", sizeof(SMCKeyData_t));
    kern_return_t kr = smc_call(&in, &out);
    if (kr != kIOReturnSuccess) {
        printf("%s: KEYINFO kr=0x%x\n", name, kr);
        return;
    }
    printf("%s: KEYINFO result=%d size=%u type=%.4s attr=0x%x", name,
           out.result, out.keyInfo.dataSize,
           (char *)&out.keyInfo.dataType, out.keyInfo.dataAttributes);
    if (out.result != 0) { printf("\n"); return; }

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_BYTES;
    in.keyInfo.dataSize = 32;
    kr = smc_call(&in, &out);
    if (kr != kIOReturnSuccess) { printf(" READ kr=0x%x\n", kr); return; }
    printf(" READ result=%d bytes=", out.result);
    for (uint32_t i = 0; i < 4; i++) printf("%02x", out.bytes[i]);
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "用法: smctool read <KEY> | smctool write <KEY> <VALUE> | smctool faninfo | smctool fanset <N> <RPM>|auto\n");
        return 2;
    }
    // macOS 15 起 AuthorizationExecuteWithPrivileges 只抬 euid 不抬 uid,
    // 故用 geteuid 判断; 再 setuid(0) 把 uid 也补齐, 兼容所有调用方式
    if (geteuid() != 0) {
        fprintf(stderr, "需要 root 权限\n");
        return 2;
    }
    setuid(0);
    if (smc_open()) return 3;

    if (strcmp(argv[1], "faninfo") == 0) {
        return cmd_faninfo();
    }
    if (strcmp(argv[1], "temps") == 0) {
        return cmd_temps();
    }
    if (strcmp(argv[1], "debug") == 0) {
        const char *keys[] = { "#KEY", "FNum", "FS!", "F0Ac", "F0Mx", "F0Md", "F0Tg", "F1Ac", "F1Md", "TC0P", "BCLM" };
        for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) dbg_read(keys[i]);
        return 0;
    }
    if (strcmp(argv[1], "debugkey") == 0) {
        if (argc < 3) return 2;
        dbg_read(argv[2]);
        return 0;
    }
    if (strcmp(argv[1], "tscan") == 0) {
        // 扫描 SMC 上所有 T 开头温度键 (iStats 式枚举), 打印可读且值合理的键
        const char *charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        char name[5] = "T...";
        for (int i = 0; charset[i]; i++) {
            name[1] = charset[i];
            for (int j = 0; charset[j]; j++) {
                name[2] = charset[j];
                for (int k = 0; charset[k]; k++) {
                    name[3] = charset[k];
                    double t = read_temp_key(name);
                    if (t > 0) printf("%s|%.1f\n", name, t);
                }
            }
        }
        return 0;
    }
    if (strcmp(argv[1], "fanset") == 0) {
        if (argc >= 3 && strcmp(argv[2], "auto") == 0) {
            return set_fan_auto();
        }
        if (argc < 4) {
            fprintf(stderr, "用法: smctool fanset <风扇编号> <RPM> | smctool fanset auto\n");
            return 2;
        }
        int idx = atoi(argv[2]);
        int rpm = atoi(argv[3]);
        if (idx < 0 || idx >= MAX_FANS) {
            fprintf(stderr, "风扇编号需在 0~%d\n", MAX_FANS - 1);
            return 2;
        }
        if (rpm < 800 || rpm > 12000) {
            fprintf(stderr, "RPM 需在 800~12000\n");
            return 2;
        }
        return set_fan_manual(idx, rpm);
    }

    if (argc < 3) {
        fprintf(stderr, "用法: smctool read <KEY> | smctool write <KEY> <VALUE>\n");
        return 2;
    }
    if (strlen(argv[2]) != 4) {
        fprintf(stderr, "键名必须为 4 个字符\n");
        return 2;
    }

    if (strcmp(argv[1], "read") == 0) {
        uint8_t buf[32];
        uint32_t size = 0;
        if (smc_read(str_to_key(argv[2]), buf, &size)) {
            fprintf(stderr, "读取 %s 失败 (该机型可能不支持此键)\n", argv[2]);
            return 4;
        }
        if (size == 1) {
            printf("%d\n", buf[0]);
        } else if (size == 2) {
            printf("%d\n", (buf[0] << 8) | buf[1]);
        } else {
            for (uint32_t i = 0; i < size; i++) printf("%02x", buf[i]);
            printf("\n");
        }
    } else if (strcmp(argv[1], "write") == 0) {
        if (argc < 4) {
            fprintf(stderr, "缺少写入值\n");
            return 2;
        }
        int v = atoi(argv[3]);
        if (v < 0 || v > 255) {
            fprintf(stderr, "写入值需在 0~255\n");
            return 2;
        }
        if (smc_write_ui8(str_to_key(argv[2]), (uint8_t)v)) {
            fprintf(stderr, "写入 %s 失败 (该机型可能不支持此键)\n", argv[2]);
            return 4;
        }
        printf("ok\n");
    } else {
        fprintf(stderr, "未知命令: %s\n", argv[1]);
        return 2;
    }
    return 0;
}
