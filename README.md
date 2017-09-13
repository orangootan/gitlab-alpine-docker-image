### Gitlab Community Edition Docker Image
Based on Alpine Linux official image.  
Built from source using Gitlab official source installation instructions with a bunch of Alpine specific fixes.  
While not heavily tested, everything seems to work including Gitaly.  

Volumes:
- /var/opt/gitlab - config, repositories and postgres data
- /var/log - logs
