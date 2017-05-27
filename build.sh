#!/bin/sh

USER=git
DIR=/var/opt/gitlab

# show execution, stop on error
set -xe

apk update && apk upgrade

# install runtime deps
apk add openssh git nginx postgresql redis nodejs icu-libs
apk add postgresql-contrib # required for extensions
apk add ruby ruby-irb ruby-io-console
apk add sudo # considered bad practice but we really need it
apk add procps # to replace busybox pkill

# install build deps
apk add gcc g++ make cmake linux-headers go python2
apk add icu-dev ruby-dev musl-dev postgresql-dev zlib-dev libffi-dev
apk add yarn --update-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/community

ssh-keygen -A # generate server keys

# create gitlab user
adduser -D -g 'GitLab' $USER
# $DIR is main mountpoint for gitlab data volume
mkdir $DIR && cd $DIR && mkdir data repo config
chown -R $USER:$USER $DIR
# openssh daemon does not allow locked user to login, change ! to *
sed -i "s/$USER:!/$USER:*/" /etc/shadow
echo "$USER ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers # sudo no tty fix

# configure nginx
mkdir /run/nginx
CONFIG=$DIR/config/nginx
mv /etc/nginx $CONFIG
ln -s $CONFIG /etc/nginx
DEFAULT=/etc/nginx/conf.d/default.conf
mv $DEFAULT $DEFAULT.bak

# configure postgres
mkdir /run/postgresql
chown postgres:postgres $DIR/data /run/postgresql
sudo -u postgres pg_ctl initdb --pgdata $DIR/data
sudo -u postgres pg_ctl start --pgdata $DIR/data
sleep 5 # wait postgres starting
sudo -u postgres psql -d template1 -c "CREATE USER $USER CREATEDB;"
sudo -u postgres psql -d template1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
sudo -u postgres psql -d template1 -c "CREATE DATABASE gitlabhq_production OWNER $USER;"
# install extension
sudo -u $USER -H psql --dbname gitlabhq_production <<CMD
SELECT true AS enabled
FROM pg_available_extensions
WHERE name = 'pg_trgm'
AND installed_version IS NOT NULL;
CMD

# setup redis
CONFIG=$DIR/config/redis.conf
SOCKET=/var/run/redis/redis.sock
cp /etc/redis.conf $CONFIG
sed --in-place "s/^port .*/port 0/" $CONFIG
echo "unixsocket $SOCKET" >>$CONFIG
echo "unixsocketperm 770" >>$CONFIG
# !--following 3 lines not needed, socket dir set up correctly by alpine redis package
# !--mkdir /var/run/redis
# !--chown redis:redis /var/run/redis
# !--chmod 755 /var/run/redis
sed --in-place "s/^redis:.*/&,git/" /etc/group # add git user to redis group
sudo -u redis redis-server $CONFIG # start redis

# adjust git settings
sudo -u $USER -H git config --global gc.auto 0
sudo -u $USER -H git config --global core.autocrlf input
sudo -u $USER -H git config --global repack.writeBitmaps true

# pull gitlab
cd /home/$USER
sudo -u $USER -H git clone https://gitlab.com/gitlab-org/gitlab-ce.git gitlab
cd /home/$USER/gitlab
sudo -u $USER -H git checkout -b docker-build-temporary v$VERSION

# configure gitlab
CONFIG=$DIR/config/gitlab
sudo -u $USER -H mkdir $CONFIG
sudo -u $USER -H cp config/gitlab.yml.example $CONFIG/gitlab.yml
sudo -u $USER -H cp config/unicorn.rb.example $CONFIG/unicorn.rb
sudo -u $USER -H cp config/resque.yml.example $CONFIG/resque.yml
sudo -u $USER -H cp config/secrets.yml.example $CONFIG/secrets.yml
sudo -u $USER -H cp config/database.yml.postgresql $CONFIG/database.yml
sudo -u $USER -H cp config/initializers/rack_attack.rb.example $CONFIG/rack_attack.rb

sudo -u $USER -H ln -s $CONFIG/* config
sudo -u $USER -H mv config/rack_attack.rb config/initializers

sed --in-place "s/# user:.*/user: $USER/" config/gitlab.yml
sed --in-place "s/host: localhost/host: $DOMAIN/" config/gitlab.yml
sed --in-place "s:/home/git/repositories:$DIR/repo:" config/gitlab.yml
sed --in-place "s:/home/git:/home/$USER:g" config/unicorn.rb
sed --in-place "s/YOUR_SERVER_FQDN/$DOMAIN/" lib/support/nginx/gitlab

# move log dir to /var/log data volume mount point
mv log /var/log/gitlab
sudo -u $USER -H ln -s /var/log/gitlab log

# set permissions
chmod o-rwx config/database.yml
chmod 0600 config/secrets.yml
chown -R $USER log/
chown -R $USER tmp/
chmod -R u+rwX,go-w log/
chmod -R u+rwX tmp/
chmod -R u+rwX tmp/pids/
chmod -R u+rwX tmp/sockets/
chmod -R u+rwX builds/
chmod -R u+rwX shared/artifacts/
chmod -R ug+rwX shared/pages/

# set repo permissions
chmod -R ug+rwX,o-rwx $DIR/repo
chmod -R ug-s $DIR/repo
find $DIR/repo -type d -print0 | sudo xargs -0 chmod g+s

# create uploads dir
sudo -u $USER -H mkdir public/uploads
chmod 0700 public/uploads

gem install bundler --version '1.14.6' --no-ri --no-rdoc # v1.15.0 bug prevents installation
gem install json --no-ri --no-rdoc # for gitlab-shell

# inject lacking gems
sudo -u $USER -H bundle inject 'bigdecimal' '> 0'
sudo -u $USER -H bundle inject 'tzinfo-data' '> 0'

# gitaly gem depends on grpc gem that seems to be incompatible with musl libc, remove it
sed --in-place "s/^gem 'gitaly'.*/#&/" Gemfile
sed --in-place "s/^require 'gitaly'/#&/" lib/gitlab/gitaly_client.rb

# to parallelize bundler jobs
CPU_COUNT=`awk '/^processor/{n+=1}END{print n}' /proc/cpuinfo`

# use no deployment option first cause we changed gemfile
sudo -u $USER -H bundle install --jobs=$CPU_COUNT --no-deployment --path vendor/bundle --without development test mysql aws kerberos

# continue as per gitlab instructions
sudo -u $USER -H bundle install --jobs=$CPU_COUNT --deployment --without development test mysql aws kerberos
sudo -u $USER -H bundle exec rake gitlab:shell:install REDIS_URL=unix:$SOCKET RAILS_ENV=production SKIP_STORAGE_VALIDATION=true
sudo -u $USER -H bundle exec rake "gitlab:workhorse:install[/home/$USER/gitlab-workhorse]" RAILS_ENV=production
echo yes | sudo -u $USER -H bundle exec rake gitlab:setup RAILS_ENV=production
sudo -u $USER -H yarn install --production --pure-lockfile
sudo -u $USER -H bundle exec rake gitlab:assets:compile RAILS_ENV=production NODE_ENV=production

# busybox pkill not compatible with -- syntax
rm /usr/bin/pkill
ln -s /bin/pkill /usr/bin/pkill
sed --in-place 's/kill --/kill/' lib/support/init.d/gitlab

# install support scripts
cp lib/support/init.d/gitlab /etc/init.d/gitlab
cp lib/support/logrotate/gitlab /etc/logrotate.d/gitlab
cp lib/support/nginx/gitlab /etc/nginx/conf.d/gitlab.conf

# install defaults for use by entrypoint script
DEFAULTS=/etc/default/gitlab
mkdir /etc/default
touch $DEFAULTS
echo "DOMAIN=$DOMAIN" >>$DEFAULTS
echo "USER=$USER" >>$DEFAULTS
echo "DIR=$DIR" >>$DEFAULTS
echo "SOCKET=$SOCKET" >>$DEFAULTS
echo "app_user=$USER" >>$DEFAULTS # for gitlab init script

# cleanup build deps
apk del go python2 yarn
apk del gcc g++ make cmake linux-headers
apk del icu-dev ruby-dev musl-dev postgresql-dev zlib-dev libffi-dev

# these dirs waste a lot of space and not needed in runtime, remove them
rm -rf node_modules .git
rm -rf /home/$USER/.cache/yarn

# cleanup sudo no tty fix
sed --in-place "/$USER.*/d" /etc/sudoers

# stop services
sudo -u postgres pg_ctl stop --mode smart --pgdata $DIR/data
sudo -u redis redis-cli -s $SOCKET shutdown
sleep 5 # wait services stopping
