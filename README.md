### Gitlab Docker Image
Experimental, for testing purposes only, not for production use!

Based on Alpine Linux official image.

Built from source using Gitlab official source installation instructions with a bunch of Alpine specific fixes.

While not heavily tested, everything seems to work except Gitaly.

Gitaly dependencies excluded from installation since grpc native gem seems to be incompatible with musl libc.

Volumes:
- /var/opt/gitlab - config, repositories and postgres data
- /var/log - logs
