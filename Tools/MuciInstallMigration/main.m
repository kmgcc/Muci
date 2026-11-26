#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <libproc.h>
#import <os/log.h>
#import <sys/event.h>
#import <sys/mount.h>
#import <unistd.h>

#import "BundleRename.h"

static NSString *const bundleID = @"kmgccc.player";
static NSString *const executablePath = @"Contents/MacOS/kmgccc_player";
static NSString *const helperPath = @"Contents/Helpers/muci-install-migration";
static NSString *const retryArgument = @"--skip-install-name-migration";

static BOOL hasOtherInstance(pid_t oldPID)
{
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
        if (app.processIdentifier != oldPID && !app.terminated) {
            return YES;
        }
    }
    return NO;
}

static BOOL hasReleaseSignature(NSURL *url, NSString *identifier)
{
    // Require the released Developer ID team and identifier before moving or
    // opening a path. The full resource seal is checked during release signing.
    NSString *rule = [NSString stringWithFormat:
        @"identifier \"%@\" and anchor apple generic and "
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
        "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and "
        "certificate leaf[subject.OU] = \"TYU73KR9WW\"", identifier];
    SecRequirementRef requirement = NULL;
    if (SecRequirementCreateWithString((__bridge CFStringRef)rule, kSecCSDefaultFlags, &requirement) != errSecSuccess) {
        return NO;
    }
    SecStaticCodeRef code = NULL;
    BOOL valid = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecStaticCodeCheckValidity(code, kSecCSDoNotValidateResources, requirement) == errSecSuccess;
    if (code != NULL) {
        CFRelease(code);
    }
    CFRelease(requirement);
    return valid;
}

static void relaunch(NSURL *url, BOOL skipMigration)
{
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    if (skipMigration) {
        configuration.arguments = @[retryArgument];
    }
    // LaunchServices reuses an existing instance if another launch won the race.
    configuration.createsNewApplicationInstance = NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url
                                       configuration:configuration
                                   completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (app == nil || error != nil) {
            os_log_error(OS_LOG_DEFAULT, "Muci migration relaunch failed (%ld)", (long)error.code);
            [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
            exit(EXIT_FAILURE);
        }
        exit(EXIT_SUCCESS);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        os_log_error(OS_LOG_DEFAULT, "Muci migration relaunch timed out");
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
        exit(EXIT_FAILURE);
    });
    dispatch_main();
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            return EXIT_FAILURE;
        }
        NSURL *source = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES].URLByStandardizingPath;
        NSURL *parent = source.URLByDeletingLastPathComponent;
        NSURL *destination = [parent URLByAppendingPathComponent:@MUCI_APP_NAME isDirectory:YES];
        NSURL *helper = [source URLByAppendingPathComponent:helperPath];
        pid_t oldPID = getppid();
        char parentExecutable[PROC_PIDPATHINFO_MAXSIZE];
        NSString *expectedExecutable = [source URLByAppendingPathComponent:executablePath].path;
        if (oldPID <= 1 || proc_pidpath(oldPID, parentExecutable, sizeof(parentExecutable)) <= 0) {
            return EXIT_FAILURE;
        }
        NSURL *actualExecutable = [NSURL fileURLWithPath:@(parentExecutable)].URLByStandardizingPath;
        if (![expectedExecutable isEqualToString:actualExecutable.path] ||
            ![source.lastPathComponent isEqualToString:@LEGACY_APP_NAME] ||
            ![source.path isEqualToString:source.URLByResolvingSymlinksInPath.path] ||
            [source.pathComponents containsObject:@"AppTranslocation"] ||
            hasOtherInstance(oldPID)) {
            return EXIT_FAILURE;
        }

        int directory = open(parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (directory < 0) {
            return EXIT_FAILURE;
        }
        struct statfs volume;
        struct stat original;
        struct stat occupied;
        if (fstatfs(directory, &volume) != 0 || (volume.f_flags & MNT_RDONLY) != 0 ||
            faccessat(directory, ".", W_OK, 0) != 0 ||
            fstatat(directory, LEGACY_APP_NAME, &original, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISDIR(original.st_mode) ||
            fstatat(directory, MUCI_APP_NAME, &occupied, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT ||
            !hasReleaseSignature(source, bundleID) ||
            !hasReleaseSignature(helper, @"muci-install-migration")) {
            return EXIT_FAILURE;
        }

        int events = kqueue();
        struct kevent watch;
        EV_SET(&watch, oldPID, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
        if (events < 0 || kevent(events, &watch, 1, NULL, 0, NULL) != 0) {
            return EXIT_FAILURE;
        }
        // Arm the process-exit watch before telling the App to hand off.
        char confirmed;
        if (write(STDOUT_FILENO, "1", 1) != 1 ||
            read(STDIN_FILENO, &confirmed, 1) != 1 || confirmed != '1') {
            return EXIT_FAILURE;
        }
        struct timespec timeout = {10, 0};
        if (kevent(events, NULL, 0, &watch, 1, &timeout) != 1 ||
            (watch.fflags & NOTE_EXIT) == 0 || hasOtherInstance(oldPID)) {
        os_log_error(OS_LOG_DEFAULT, "Muci migration stopped before rename: exit not observed or another instance is running");
            return EXIT_FAILURE;
        }

        // The path and signature must still match after the App exits. The
        // exclusive rename is atomic, including if a target appeared meanwhile.
        if (hasReleaseSignature(source, bundleID) && renameBundle(directory, &original)) {
            if (matchesDirectory(directory, MUCI_APP_NAME, &original) &&
                hasReleaseSignature(destination, bundleID)) {
                relaunch(destination, NO);
            }
        } else if (matchesDirectory(directory, LEGACY_APP_NAME, &original) &&
                   hasReleaseSignature(source, bundleID)) {
            relaunch(source, YES);
        }
        return EXIT_FAILURE;
    }
}
