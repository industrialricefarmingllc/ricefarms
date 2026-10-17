// chvt-fast — SUID VT switch helper for ricefarms desktop-toggle.
// Behavior (matches /usr/local/bin/chvt-fast 16360B SUID):
//   chvt-fast <N>  -> VT_ACTIVATE N + VT_WAITACTIVE (timeout ~15s)
// Why not plain `chvt`: desktop-toggle wraps with timeout + flock and prefers
// logind Seat.SwitchTo; chvt-fast is the low-level fallback for
// CTRL+ALT+Delete (chvt 2) / CTRL+ALT+F1 (chvt 1) binds.
// Build: cc -O2 chvt-fast.c -o /usr/local/bin/chvt-fast && chmod 4755 /usr/local/bin/chvt-fast
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/vt.h>
#include <signal.h>

static void on_alarm(int s) { (void)s; _exit(124); }

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <vt-number>\n", argv[0]); return 2; }
    int vt = atoi(argv[1]);
    if (vt < 1 || vt > 63) { fprintf(stderr, "bad vt: %s\n", argv[1]); return 2; }
    int fd = open("/dev/tty0", O_RDWR | O_NOCTTY);
    if (fd < 0) { perror("open /dev/tty0"); return 1; }
    signal(SIGALRM, on_alarm);
    alarm(15);
    if (ioctl(fd, VT_ACTIVATE, vt) < 0) { perror("VT_ACTIVATE"); return 1; }
    if (ioctl(fd, VT_WAITACTIVE, vt) < 0) { perror("VT_WAITACTIVE"); return 1; }
    alarm(0);
    close(fd);
    return 0;
}
