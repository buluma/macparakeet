// Standalone experiment for #1286. Only run on a disposable hosted CI desktop.
// No text, clipboard data, or user input is captured. F20 is the only test key.
#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static const CGKeyCode testKey = 90; // F20; no text or modifier chord.
static const int64_t marker = 0x4D50524F4245;
static CGEventSourceRef activeSource;
static CGEventTapLocation activeLocation;

static void snapshot(const char *phase) {
    printf("{\"phase\":\"%s\",\"pid\":%d,\"session_down\":%s,\"hid_down\":%s}\n",
           phase, getpid(),
           CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, testKey) ? "true" : "false",
           CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, testKey) ? "true" : "false");
    fflush(stdout);
}

static bool post(bool down) {
    CGEventRef event = CGEventCreateKeyboardEvent(activeSource, testKey, down);
    if (!event) return false;
    CGEventSetFlags(event, 0);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, marker);
    CGEventPost(activeLocation, event);
    CFRelease(event);
    return true;
}

static void cleanup(void) {
    if (!activeSource) return;
    post(false);
    usleep(100000);
    CFRelease(activeSource);
    activeSource = NULL;
}

static bool allUp(void) {
    return !CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, testKey)
        && !CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, testKey);
}

static void freshReader(const char *executable) {
    pid_t child = fork();
    if (child == 0) {
        execl(executable, executable, "--read-only", NULL);
        _exit(127);
    }
    if (child < 0) exit(1);
    int status;
    if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) exit(1);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--read-only") == 0) {
        snapshot("fresh_process");
        return 0;
    }
    const char *ci = getenv("GITHUB_ACTIONS");
    const char *runner = getenv("RUNNER_ENVIRONMENT");
    if (!ci || strcmp(ci, "true") || !runner || strcmp(runner, "github-hosted")) {
        fprintf(stderr, "Refusing global input outside a disposable GitHub-hosted runner.\n");
        return 1;
    }
    printf("{\"post_access\":%s}\n", CGPreflightPostEventAccess() ? "true" : "false");
    if (!CGPreflightPostEventAccess()) {
        puts("{\"result\":\"unavailable\",\"reason\":\"event_post_permission\"}");
        return 0;
    }
    atexit(cleanup);
    CGEventSourceStateID states[] = {kCGEventSourceStateHIDSystemState,
        kCGEventSourceStateCombinedSessionState, kCGEventSourceStatePrivate};
    CGEventTapLocation locations[] = {kCGHIDEventTap, kCGSessionEventTap};
    for (unsigned location = 0; location < 2; location++) {
        for (unsigned state = 0; state < 3; state++) {
            if (!allUp()) {
                fprintf(stderr, "Test key already down; refusing to alter existing input.\n");
                return 1;
            }
            activeSource = CGEventSourceCreate(states[state]);
            activeLocation = locations[location];
            if (!activeSource) return 1;
            printf("{\"source_state\":%d,\"post_location\":%u}\n", states[state], locations[location]);
            snapshot("before");
            if (!post(true)) return 1;
            usleep(200000);
            snapshot("down_without_up");
            freshReader(argv[0]);
            if (!post(false)) return 1;
            usleep(200000);
            snapshot("released");
            cleanup();
            snapshot("source_destroyed");
            if (!allUp()) return 1;
        }
    }
    puts("{\"result\":\"observed\",\"physical_holds_tested\":false,\"jump_desktop_tested\":false}");
    return 0;
}
