#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/stat.h>

#define LEGACY_APP_NAME "kmgccc_player.app"
#define MUCI_APP_NAME "Muci.app"

static bool matchesDirectory(int parent, const char *name, const struct stat *expected)
{
    struct stat current;
    return fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISDIR(current.st_mode) &&
        current.st_dev == expected->st_dev && current.st_ino == expected->st_ino;
}

static bool renameBundle(int parent, const struct stat *expected)
{
    return matchesDirectory(parent, LEGACY_APP_NAME, expected) &&
        renameatx_np(parent, LEGACY_APP_NAME, parent, MUCI_APP_NAME,
                     RENAME_EXCL | RENAME_NOFOLLOW_ANY) == 0;
}
