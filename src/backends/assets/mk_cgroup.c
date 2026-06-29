#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <limits.h>
#include <linux/limits.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <libgen.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <stdint.h>

#define min(x, y)       ((x) < (y) ? (x) : (y))

typedef enum {
    CGROUP_MODE_UNKNOWN = 0,
    CGROUP_MODE_V1,
    CGROUP_MODE_V2,
} cgroup_mode_t;

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
    dir_dirname[PATH_MAX - 1] = '\0';
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

        struct stat entry_sb;
        if (stat(leaf_path, &entry_sb) == 0 && S_ISDIR(entry_sb.st_mode)) {
            if (chown_r(leaf_path, uid, gid) != 0) {
                return 1;
            }
        }
    }
    closedir(dir);

    return 0;
}

static int read_contents(const char *path, char *buff, size_t buff_size) {
    int fd = open(path, O_RDONLY);
    if (fd == -1) {
        return -1;
    }
    int bytes_read = read(fd, buff, buff_size);
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    return bytes_read;
}

static int write_contents(const char *path, const char *buff, size_t buff_size) {
    int fd = open(path, O_WRONLY);
    if (fd == -1) {
        return -1;
    }
    ssize_t bytes_written = write(fd, buff, buff_size);
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    if (bytes_written != (ssize_t) buff_size) {
        return -1;
    }
    return 0;
}

static int append_path_component(char *path, size_t path_size, const char *component) {
    size_t path_len = strlen(path);
    size_t component_len = strlen(component);
    int needs_slash = path_len > 0 && path[path_len - 1] != '/';
    size_t needed = path_len + (needs_slash ? 1 : 0) + component_len + 1;
    if (needed > path_size) {
        return 1;
    }
    if (needs_slash) {
        path[path_len++] = '/';
    }
    memcpy(path + path_len, component, component_len + 1);
    return 0;
}

static int string_contains_token(const char *text, int text_len, const char *token) {
    size_t token_len = strlen(token);
    int idx = 0;
    while (idx < text_len) {
        while (idx < text_len && (text[idx] == ' ' || text[idx] == '\n' || text[idx] == '\t')) {
            idx++;
        }
        int start = idx;
        while (idx < text_len && text[idx] != ' ' && text[idx] != '\n' && text[idx] != '\t') {
            idx++;
        }
        int end = idx;
        if ((size_t) (end - start) == token_len && strncmp(text + start, token, token_len) == 0) {
            return 1;
        }
    }
    return 0;
}

static cgroup_mode_t detect_cgroup_mode(void) {
    if (access("/sys/fs/cgroup/cgroup.controllers", R_OK) == 0) {
        return CGROUP_MODE_V2;
    }

    struct stat sb;
    if (stat("/sys/fs/cgroup/cpuset", &sb) == 0 && S_ISDIR(sb.st_mode)) {
        return CGROUP_MODE_V1;
    }

    return CGROUP_MODE_UNKNOWN;
}

static int copy_string(char *dst, size_t dst_size, const char *src) {
    int n = snprintf(dst, dst_size, "%s", src);
    return n > 0 && (size_t) n < dst_size;
}

static int has_subtree_control_file(const char *cgroup_path) {
    char subtree_control_path[PATH_MAX];
    int n = snprintf(subtree_control_path, sizeof(subtree_control_path), "%s/cgroup.subtree_control", cgroup_path);
    if (n <= 0 || (size_t) n >= sizeof(subtree_control_path)) {
        return 0;
    }

    struct stat sb;
    if (stat(subtree_control_path, &sb) != 0) {
        return 0;
    }
    return S_ISREG(sb.st_mode);
}

static int resolve_v2_cgroup_root(uid_t uid, char *path, size_t path_size) {
    char user_service_path[PATH_MAX];
    snprintf(user_service_path, sizeof(user_service_path),
             "/sys/fs/cgroup/user.slice/user-%ju.slice/user@%ju.service",
             (uintmax_t) uid, (uintmax_t) uid);
    struct stat sb;
    if (stat(user_service_path, &sb) == 0 && S_ISDIR(sb.st_mode) && has_subtree_control_file(user_service_path)) {
        return copy_string(path, path_size, user_service_path) ? 0 : 1;
    }

    // Fallback to this process's own cgroup path.
    FILE *f = fopen("/proc/self/cgroup", "r");
    if (!f) {
        return 1;
    }
    char line[PATH_MAX];
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, "0::", 3) == 0) {
            char *cgroup_path = line + 3;
            size_t len = strlen(cgroup_path);
            while (len > 0 && (cgroup_path[len - 1] == '\n' || cgroup_path[len - 1] == '\r')) {
                cgroup_path[len - 1] = '\0';
                len--;
            }
            if (len == 0) {
                break;
            }
            if (strcmp(cgroup_path, "/") == 0) {
                fclose(f);
                if (has_subtree_control_file("/sys/fs/cgroup")) {
                    return copy_string(path, path_size, "/sys/fs/cgroup") ? 0 : 1;
                }
                return 1;
            }

            char candidate[PATH_MAX];
            int n = snprintf(candidate, sizeof(candidate), "/sys/fs/cgroup%s", cgroup_path);
            fclose(f);
            if (n <= 0 || (size_t) n >= sizeof(candidate)) {
                return 1;
            }
            if (has_subtree_control_file(candidate)) {
                return copy_string(path, path_size, candidate) ? 0 : 1;
            }

            // If our current cgroup is a leaf without delegation files,
            // fall back to the unified root as a last resort.
            if (has_subtree_control_file("/sys/fs/cgroup")) {
                return copy_string(path, path_size, "/sys/fs/cgroup") ? 0 : 1;
            }
            return 1;
        }
    }
    fclose(f);
    return 1;
}

static int resolve_cgroup_root(cgroup_mode_t mode, uid_t uid, char *path, size_t path_size) {
    if (mode == CGROUP_MODE_V1) {
        return copy_string(path, path_size, "/sys/fs/cgroup/cpuset") ? 0 : 1;
    }
    return resolve_v2_cgroup_root(uid, path, path_size);
}

static int ensure_v2_cpuset_enabled(const char *cgroup_root) {
    char relative_root[PATH_MAX];
    if (strncmp(cgroup_root, "/sys/fs/cgroup", strlen("/sys/fs/cgroup")) != 0) {
        fprintf(stderr, "Unexpected cgroup root: %s\n", cgroup_root);
        return 1;
    }

    if (!copy_string(relative_root, sizeof(relative_root), cgroup_root + strlen("/sys/fs/cgroup"))) {
        return 1;
    }

    char current_path[PATH_MAX];
    if (!copy_string(current_path, sizeof(current_path), "/sys/fs/cgroup")) {
        return 1;
    }

    char *remaining = relative_root;
    while (remaining[0] == '/') {
        remaining++;
    }

    while (1) {
        char controllers_path[PATH_MAX];
        int n = snprintf(controllers_path, sizeof(controllers_path), "%s/cgroup.controllers", current_path);
        if (n <= 0 || (size_t) n >= sizeof(controllers_path)) {
            return 1;
        }

        char controllers[512];
        int controllers_len = read_contents(controllers_path, controllers, sizeof(controllers));
        if (controllers_len <= 0) {
            return 1;
        }
        if (!string_contains_token(controllers, controllers_len, "cpuset")) {
            fprintf(stderr, "cpuset controller is unavailable at %s\n", current_path);
            return 1;
        }

        char subtree_control_path[PATH_MAX];
        n = snprintf(subtree_control_path, sizeof(subtree_control_path), "%s/cgroup.subtree_control", current_path);
        if (n <= 0 || (size_t) n >= sizeof(subtree_control_path)) {
            return 1;
        }

        char subtree_control[512];
        int subtree_len = read_contents(subtree_control_path, subtree_control, sizeof(subtree_control));
        if (subtree_len < 0 && errno == ENOENT) {
            fprintf(stderr, "cgroup.subtree_control does not exist at %s\n", subtree_control_path);
            return 1;
        }

        if (subtree_len <= 0 || !string_contains_token(subtree_control, subtree_len, "cpuset")) {
            if (write_contents(subtree_control_path, "+cpuset", strlen("+cpuset")) != 0) {
                perror("Unable to enable cpuset in cgroup.subtree_control");
                return 1;
            }
        }

        if (remaining[0] == '\0') {
            return 0;
        }

        char *separator = strchr(remaining, '/');
        if (separator != NULL) {
            *separator = '\0';
        }
        if (append_path_component(current_path, sizeof(current_path), remaining) != 0) {
            return 1;
        }
        if (separator == NULL) {
            remaining += strlen(remaining);
        } else {
            remaining = separator + 1;
        }
        while (remaining[0] == '/') {
            remaining++;
        }
    }
}

static int read_parent_mems(cgroup_mode_t mode, const char *root, char *buff, size_t buff_size) {
    char path[PATH_MAX];
    if (mode == CGROUP_MODE_V1) {
        int n = snprintf(path, sizeof(path), "%s/cpuset.mems", root);
        if (n <= 0 || (size_t) n >= sizeof(path)) {
            return -1;
        }
        return read_contents(path, buff, buff_size);
    }

    int n = snprintf(path, sizeof(path), "%s/cpuset.mems", root);
    if (n <= 0 || (size_t) n >= sizeof(path)) {
        return -1;
    }
    int bytes_read = read_contents(path, buff, buff_size);
    if (bytes_read > 0) {
        return bytes_read;
    }
    n = snprintf(path, sizeof(path), "%s/cpuset.mems.effective", root);
    if (n <= 0 || (size_t) n >= sizeof(path)) {
        return -1;
    }
    bytes_read = read_contents(path, buff, buff_size);
    if (bytes_read > 0) {
        return bytes_read;
    }

    // On some systems, delegated roots may not expose cpuset.mems directly
    // until parent delegation is complete. Fall back to the parent cgroup.
    char parent[PATH_MAX];
    strncpy(parent, root, sizeof(parent) - 1);
    parent[sizeof(parent) - 1] = '\0';
    char *parent_dir = dirname(parent);
    n = snprintf(path, sizeof(path), "%s/cpuset.mems", parent_dir);
    if (n > 0 && (size_t) n < sizeof(path)) {
        bytes_read = read_contents(path, buff, buff_size);
        if (bytes_read > 0) {
            return bytes_read;
        }
    }
    n = snprintf(path, sizeof(path), "%s/cpuset.mems.effective", parent_dir);
    if (n > 0 && (size_t) n < sizeof(path)) {
        bytes_read = read_contents(path, buff, buff_size);
        if (bytes_read > 0) {
            return bytes_read;
        }
    }

    // Last resort for v2 hierarchy.
    return read_contents("/sys/fs/cgroup/cpuset.mems.effective", buff, buff_size);
}

static const char * process_join_file(cgroup_mode_t mode) {
    if (mode == CGROUP_MODE_V1) {
        return "tasks";
    }
    return "cgroup.procs";
}

static int verify_cgroup(cgroup_mode_t mode, const char *root, const char * name, uid_t uid, gid_t gid, const char * cpus) {
    // First, check if the directory exists:
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s", root, name);
    struct stat sb;
    if (stat(path, &sb) != 0 || !S_ISDIR(sb.st_mode)) {
        return 1;
    }

    // Ensure it's owned by the right uid and gid
    if (sb.st_uid != uid || sb.st_gid != gid) {
        return 1;
    }

    // Ensure the file used for process attachment has expected ownership too.
    // Without this, stale cgroups created under an older ownership model can
    // pass verification while still rejecting writes from inside the sandbox.
    snprintf(path, sizeof(path), "%s/%s/%s", root, name, process_join_file(mode));
    if (stat(path, &sb) != 0) {
        return 1;
    }
    if (sb.st_uid != uid || sb.st_gid != gid) {
        return 1;
    }

    // Ensure the assigned cpus are correct
    snprintf(path, sizeof(path), "%s/%s/cpuset.cpus", root, name);
    char buff[128];
    int bytes_read = read_contents(path, buff, sizeof(buff));
    if (bytes_read <= 0) {
        return 1;
    }
    if (strncmp(cpus, buff, min(bytes_read, strlen(cpus))) != 0) {
        return 1;
    }

    // Ensure the assigned mems are correct
    snprintf(path, sizeof(path), "%s/%s/cpuset.mems", root, name);
    bytes_read = read_contents(path, buff, sizeof(buff));
    if (bytes_read <= 0) {
        return 1;
    }

    char true_mems[128];
    int true_mems_len = read_parent_mems(mode, root, true_mems, sizeof(true_mems));
    if (true_mems_len <= 0) {
        return 1;
    }
    if (strncmp(true_mems, buff, min(true_mems_len, bytes_read)) != 0) {
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

    cgroup_mode_t mode = detect_cgroup_mode();
    if (mode == CGROUP_MODE_UNKNOWN) {
        fprintf(stderr, "Unable to detect cgroup mode; expected v1 cpuset or unified v2\n");
        return 1;
    }

    char root[PATH_MAX];
    check(resolve_cgroup_root(mode, uid, root, sizeof(root)) == 0);

    if (mode == CGROUP_MODE_V2) {
        check(ensure_v2_cpuset_enabled(root) == 0);
    }

    if (verify_cgroup(mode, root, name, uid, gid, cpus) == 0) {
        // We can exit out immediately without doing anything
        return 0;
    }

    // First, create the cpuset
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s", root, name);
    mkpath(path);

    // Chown it (recursively) to the appropriate user
    check(chown_r(path, uid, gid) == 0);

    // Copy from the global mems
    char mems_contents[128];
    int mems_contents_len = read_parent_mems(mode, root, mems_contents, sizeof(mems_contents));
    check(mems_contents_len > 0);
    check(mems_contents_len <= sizeof(mems_contents));

    // Into our new mems (must be set before cpuset.cpus on cgroup v2)
    snprintf(path, sizeof(path), "%s/%s/cpuset.mems", root, name);
    check(write_contents(path, mems_contents, mems_contents_len) == 0);

    // Next, assign the appropriate cpus to it
    snprintf(path, sizeof(path), "%s/%s/cpuset.cpus", root, name);
    int fd = open(path, O_WRONLY);
    if (fd == -1 && mode == CGROUP_MODE_V1) {
        fprintf(stderr, "%s not found, ensure cpuset cgroup v1 is mounted!\n", path);
    } else if (fd == -1 && mode == CGROUP_MODE_V2) {
        fprintf(stderr, "%s not found, ensure cpuset controller is enabled on cgroup v2!\n", path);
    }
    check(fd != -1);
    check(write(fd, cpus, strlen(cpus)) == strlen(cpus));
    check(close(fd) == 0);

    // Verify to ensure that everything went well
    check(verify_cgroup(mode, root, name, uid, gid, cpus) == 0);
    return 0;
 }
