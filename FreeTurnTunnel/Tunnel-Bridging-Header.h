// sys/kern_control.h is not part of the public iOS SDK, even though the
// underlying kernel control-socket ABI (used to find the utun fd behind
// NEPacketTunnelFlow) is stable and usable from an app extension. Every
// userspace-WireGuard iOS client declares these structs by hand for the
// same reason — mirrors XNU's <sys/kern_control.h> exactly.
#include <sys/ioctl.h>
#include <stdint.h>

#define MAX_KCTL_NAME 96

struct ctl_info {
    uint32_t ctl_id;
    char ctl_name[MAX_KCTL_NAME];
};

struct sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};

// Swift's Clang importer doesn't reliably import function-like macros with
// shift expressions (_IOWR expands via _IOC), so materialize it as a real
// C constant Swift can see.
static const unsigned long FT_CTLIOCGINFO = _IOWR('N', 3, struct ctl_info);
