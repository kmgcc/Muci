#include <assert.h>
#include <stdlib.h>
#include <unistd.h>

#include "../../Tools/MuciInstallMigration/BundleRename.h"

int main(int argc, char *argv[])
{
    assert(argc == 2);
    int parent = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    assert(parent >= 0);
    struct stat original;
    assert(mkdirat(parent, LEGACY_APP_NAME, 0700) == 0);
    assert(fstatat(parent, LEGACY_APP_NAME, &original, AT_SYMLINK_NOFOLLOW) == 0);

    // A directory, regular file or dangling symlink at the target stays put.
    assert(mkdirat(parent, MUCI_APP_NAME, 0700) == 0);
    assert(!renameBundle(parent, &original));
    assert(unlinkat(parent, MUCI_APP_NAME, AT_REMOVEDIR) == 0);
    int occupied = openat(parent, MUCI_APP_NAME, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(occupied >= 0);
    assert(close(occupied) == 0);
    assert(!renameBundle(parent, &original));
    assert(unlinkat(parent, MUCI_APP_NAME, 0) == 0);
    assert(symlinkat("missing", parent, MUCI_APP_NAME) == 0);
    assert(!renameBundle(parent, &original));
    assert(unlinkat(parent, MUCI_APP_NAME, 0) == 0);

    // The source identity saved before handoff must still match.
    assert(renameat(parent, LEGACY_APP_NAME, parent, "original") == 0);
    assert(symlinkat("original", parent, LEGACY_APP_NAME) == 0);
    assert(!renameBundle(parent, &original));
    assert(unlinkat(parent, LEGACY_APP_NAME, 0) == 0);
    assert(mkdirat(parent, LEGACY_APP_NAME, 0700) == 0);
    assert(!renameBundle(parent, &original));
    assert(unlinkat(parent, LEGACY_APP_NAME, AT_REMOVEDIR) == 0);

    assert(renameat(parent, "original", parent, LEGACY_APP_NAME) == 0);
    assert(renameBundle(parent, &original));
    assert(matchesDirectory(parent, MUCI_APP_NAME, &original));
    assert(!renameBundle(parent, &original));
    assert(close(parent) == 0);
}
