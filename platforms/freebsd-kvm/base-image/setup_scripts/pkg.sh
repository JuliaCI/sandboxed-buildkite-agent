#!/bin/sh
set -e

# FreeBSD 13 is EOL and pkg.FreeBSD.org no longer serves its packages. Point the
# FreeBSD repository at a mirror that retained the FreeBSD 13 packages, still
# verified against FreeBSD's signing keys. The bootstrap pkg(7) takes the whole repository
# entry from the last file that defines it, so the signature settings must be
# repeated here. The file stays in the image for the worker stage and jobs.
if [ "$(freebsd-version -u | cut -d. -f1)" = 13 ]; then
    mkdir -p /usr/local/etc/pkg/repos
    cat > /usr/local/etc/pkg/repos/FreeBSD.conf <<'EOF'
FreeBSD: {
  url: "https://mirrors.aliyun.com/freebsd-pkg/${ABI}/quarterly",
  mirror_type: "none",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg"
}
EOF
fi

env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
pkg upgrade -q -y
pkg install -q -y bash ca_root_nss ccache cmake curl gcc git gmake m4 pkgconf python sudo
