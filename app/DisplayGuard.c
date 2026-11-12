#include "DisplayHardware.h"
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t stopping = 0;
static void stop(int signalNumber) { (void)signalNumber; stopping = 1; }

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--inspect") == 0) {
        printf("{\"builtin\":%u,\"studios\":%u,\"available\":%s}\n",
               SPBuiltinDisplay(), SPStudioDisplayCount(), SPDisplayControlAvailable() ? "true" : "false");
        return 0;
    }
    if (argc != 3) return 64;
    char *end = NULL; unsigned long value = strtoul(argv[2], &end, 10);
    if (!value || value > UINT32_MAX || *end) return 64;
    CGDirectDisplayID id = (CGDirectDisplayID)value;
    if (strcmp(argv[1], "--restore") == 0) return SPSetDisplayEnabled(id, true) == 0 ? 0 : 1;
    if (strcmp(argv[1], "--watch") != 0) return 64;
    if (id != SPBuiltinDisplay() || !SPDisplayActive(id) || SPStudioDisplayCount() < 2) return 65;
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, stop); signal(SIGPIPE, SIG_IGN);
    // The open pipe proves the owner is alive. EOF also arrives on SIGKILL/crash.
    struct pollfd owner = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP };
    if (poll(&owner, 1, 0) > 0 && (owner.revents & (POLLHUP | POLLERR | POLLNVAL))) return 66;
    int result = SPSetDisplayEnabled(id, false);
    if (result == 0) {
        puts("off"); fflush(stdout);
        while (!stopping && SPStudioDisplayCount() >= 2 && !SPDisplayActive(id)) {
            owner.revents = 0;
            int ready = poll(&owner, 1, 250);
            if (ready > 0) {
                char command[16];
                if (owner.revents & (POLLHUP | POLLERR | POLLNVAL)) break;
                if ((owner.revents & POLLIN) && read(STDIN_FILENO, command, sizeof command) <= 0) break;
            } else if (ready < 0 && errno != EINTR) break;
        }
    }
    // A failed disconnect can still have partially changed the layout.
    // Keep trying recovery while the owner exits; never leave it disabled knowingly.
    while (SPSetDisplayEnabled(id, true) != 0) sleep(1);
    puts("restored"); fflush(stdout);
    return result == 0 ? 0 : 1;
}
