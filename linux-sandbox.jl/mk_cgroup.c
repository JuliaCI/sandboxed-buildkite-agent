#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <linux/limits.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <libgen.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>

#define min(x, y)       ((x) < (y) ? (x) : (y))

/* Like assert, but don't go away with optimizations */
static void _check(int ok, int line) {
    if (!ok) {
        fprintf(stderr, "At line %d, ABORTED (%d: %s)!\n", line, errno, strerror(errno));
        fflush(stdout);
        fflush(stderr);
        exit(1);
    }
}
#define check(ok) _check(ok, __LINE__)

/* Make all directories up to the given directory name. */
static void mkpath(const char * dir) {
    struct stat sb;
    if (stat(dir, &sb) == 0 && S_ISDIR(sb.st_mode)) {
        return;
    }
    // Otherwise, first make sure our parent exists.  Note that dirname()
    // clobbers its input, so we copy to a temporary variable first. >:|
    char dir_dirname[PATH_MAX];
    strncpy(dir_dirname, dir, PATH_MAX - 1);
    mkpath(dirname(&dir_dirname[0]));

    // then create our directory
    int result = mkdir(dir, 0777);
    check((0 == result));
}

static int chown_r(const char * path, uid_t uid, gid_t gid) {
    DIR * dir = opendir(path);
    if (!dir) {
        return 1;
    }
    check(chown(path, uid, gid) == 0);

    struct dirent *entry;
    char leaf_path[PATH_MAX];
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;

        snprintf(leaf_path, sizeof(leaf_path), "%s/%s", path, entry->d_name);
        check(chown(leaf_path, uid, gid) == 0);

        if (entry->d_type == DT_DIR) {
            if (chown_r(leaf_path, uid, gid) != 0) {
                return 1;
            }
        }
    }
    closedir(dir);

    return 0;
}

static int verify_cgroup(const char * name, uid_t uid, gid_t gid, const char * cpus) {
    // First, check if the directory exists:
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "/sys/fs/cgroup/cpuset/%s", name);
    struct stat sb;
    if (stat(path, &sb) != 0 || !S_ISDIR(sb.st_mode)) {
        return 1;
    }

    // Ensure it's owned by the right uid and gid
    if (sb.st_uid != uid || sb.st_gid != gid) {
        return 1;
    }

    // Ensure the assigned cpus are correct
    snprintf(path, sizeof(path), "/sys/fs/cgroup/cpuset/%s/cpuset.cpus", name);
    int fd = open(path, O_RDONLY);
    if (fd == -1) {
        return 1;
    }
    char buff[128];
    int bytes_read = read(fd, buff, sizeof(buff));
    close(fd);
    if (bytes_read <= 0) {
        return 1;
    }
    if (strncmp(cpus, buff, min(bytes_read, strlen(cpus))) != 0) {
        return 1;
    }

    // Ensure the assigned mems are correct
    snprintf(path, sizeof(path), "/sys/fs/cgroup/cpuset/%s/cpuset.mems", name);
    fd = open(path, O_RDONLY);
    if (fd == -1) {
        return 1;
    }
    bytes_read = read(fd, buff, sizeof(buff));
    close(fd);
    if (bytes_read <= 0) {
        return 1;
    }

    snprintf(path, sizeof(path), "/sys/fs/cgroup/cpuset/cpuset.mems");
    fd = open(path, O_RDONLY);
    if (fd == -1) {
        return 1;
    }
    char true_mems[128];
    bytes_read = read(fd, true_mems, sizeof(true_mems));
    if (bytes_read <= 0) {
        return 1;
    }
    if (strncmp(true_mems, buff, bytes_read) != 0) {
        return 1;
    }

    // If all of those tests passed, the cgroup is setup correctly!
    return 0;
}

int main(int argc, char * argv[]) {
    if( argc < 3 ) {
        fprintf(stderr, "Usage: mk_cgroup <name> <cpus>\n");
        return 1;
    }
    const char * name = argv[1];
    const char * cpus = argv[2];
    uid_t uid = getuid();
    gid_t gid = getgid();

    if (verify_cgroup(name, uid, gid, cpus) == 0) {
        // We can exit out immediately without doing anything
        return 0;
    }

    // First, create the cpuset
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "/sys/fs/cgroup/cpuset/%s", name);
    mkpath(path);

    // Chown it (recursively) to the appropriate user
    check(chown_r(path, uid, gid) == 0);

    // Next, assign the appropriate cpus to it
    snprintf(path, sizeof(path), "/sys/fs/cgroup/cpuset/%s/cpuset.cpus", name);
    int fd = open(path, O_WRONLY);
    if (fd == -1) {
        fprintf(stderr, "%s not found, ensure you're running with cgroups v1!\n", path);
    }
    check(fd != -1);
    check(write(fd, cpus, strlen(cpus)) == strlen(cpus));
    check(close(fd) == 0);

    // Copy from the global mems
    snprintf(path, sizeof(path), "/sys/fs/cgroup/cpuset/cpuset.mems");
    fd = open(path, O_RDONLY);
    check(fd != -1);
    char mems_contents[128];
    int mems_contents_len = read(fd, mems_contents, sizeof(mems_contents));
    check(mems_contents_len > 0);
    check(mems_contents_len <= sizeof(mems_contents));
    check(close(fd) == 0);

    // Into our new mems
    snprintf(path, sizeof(path), "/sys/fs/cgroup/cpuset/%s/cpuset.mems", name);
    fd = open(path, O_WRONLY);
    check(fd != -1);
    check(write(fd, mems_contents, mems_contents_len) == mems_contents_len);
    check(close(fd) == 0);

    // Verify to ensure that everything went well
    check(verify_cgroup(name, uid, gid, cpus) == 0);
    return 0;
 }
