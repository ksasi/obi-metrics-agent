# Install the EPEL yum repository
sudo rpm -Uvh http://dl.fedoraproject.org/pub/epel/6/`uname -p`/epel-release-6-8.noarch.rpm

# Install dependencies
# Install packages through yum
sudo yum install -y python-pip python-devel pycairo-devel bitmap-fonts httpd mod_wsgi mod_python git python-virtualenv libffi libffi-devel

# Using virtualenv, create a standalone environment in which Graphite will run
virtualenv /home/oracle/graphite
source /home/oracle/graphite/bin/activate

# Install Python libraries
pip install django django-tagging 'Twisted<12.0' pyparsing pytz cairocffi

# Download and compile graphite and supporting components
cd /home/oracle
git clone https://github.com/graphite-project/graphite-web.git 
git clone https://github.com/graphite-project/carbon.git 
git clone https://github.com/graphite-project/whisper.git 
git clone https://github.com/graphite-project/ceres.git 

cd /home/oracle/graphite-web && python setup.py install --prefix=/home/oracle/graphite --install-lib=/home/oracle/graphite/lib
cd /home/oracle/carbon && python setup.py install --prefix=/home/oracle/graphite --install-lib=/home/oracle/graphite/lib
cd /home/oracle/whisper && python setup.py install --prefix=/home/oracle/graphite --install-lib=/home/oracle/graphite/lib
cd /home/oracle/ceres && python setup.py install --prefix=/home/oracle/graphite --install-lib=/home/oracle/graphite/lib

cd /home/oracle

# Two manual steps
mkdir -p /home/oracle/graphite/storage/log/carbon-cache/carbon-cache-a  

# Enable carbon-cache to start at bootup
sed -i -e 's/^GRAPHITE_DIR.*$//g' /home/oracle/carbon/distro/redhat/init.d/carbon-cache
sed -i -e '/export PYTHONPATH/i export GRAPHITE_DIR="\/home\/oracle\/graphite"' /home/oracle/carbon/distro/redhat/init.d/carbon-cache
sed -i -e 's/chkconfig.*$/chkconfig: 345 95 20/g' /home/oracle/carbon/distro/redhat/init.d/carbon-cache

sudo cp /home/oracle/carbon/distro/redhat/init.d/carbon-cache /etc/init.d
sudo chmod 750 /etc/init.d/carbon-cache
sudo chkconfig --add carbon-cache

# Configure Carbon (graphite's storage engine)
cd /home/oracle/graphite/conf/
cp carbon.conf.example carbon.conf
sed -i -e 's/MAX_CREATES_PER_MINUTE = 50/MAX_CREATES_PER_MINUTE = inf/' carbon.conf
# Defaults to 7002, which is also the AdminServer SSL port so may well be taken.
sed -i -e 's/CACHE_QUERY_PORT = 7002/CACHE_QUERY_PORT = 17002/' carbon.conf
# Create storage-schemas.conf
cat>storage-schemas.conf<<EOF
[default_5sec_for_14day]
pattern = .*
retentions = 5s:14d
EOF

# Start carbon cache
# If this is outside the original install session, you'll need to run the "source" command again
source /home/oracle/graphite/bin/activate
cd /home/oracle/graphite/
./bin/carbon-cache.py start

# Set up graphite web application in Apache

sudo cp /home/oracle/graphite/examples/example-graphite-vhost.conf /etc/httpd/conf.d/graphite-vhost.conf
sudo sed -i -e 's/WSGISocketPrefix.*$/WSGISocketPrefix \/etc\/httpd\/wsgi\//' /etc/httpd/conf.d/graphite-vhost.conf
sudo sed -i -e 's/\/opt\/graphite/\/home\/oracle\/graphite/' /etc/httpd/conf.d/graphite-vhost.conf
sudo sed -i -e 's/modules\/mod_wsgi.so/modules\/mod_wsgi.so/' /etc/httpd/conf.d/graphite-vhost.conf
sudo mkdir -p /etc/httpd/wsgi
cp /home/oracle/graphite/conf/graphite.wsgi.example /home/oracle/graphite/conf/graphite.wsgi
# This needs to match whatever --install-lib was set to when running setup.py install for graphite-web 
sed -i -e 's/\/opt\/graphite\/webapp/\/home\/oracle\/graphite\/lib/' /home/oracle/graphite/conf/graphite.wsgi

# Frig permissions so apache can access the webapp
chmod o+rx /home/oracle
chmod -R o+rx /home/oracle/graphite

# Set graphite web app settings

# This needs to match whatever --install-lib was set to when running setup.py install for graphite-web
cd /home/oracle/graphite/lib/graphite
cp local_settings.py.example local_settings.py
sed -i -e "/TIME_ZONE/a TIME_ZONE = \'Europe\/London\'" local_settings.py
sed -i -e "s/#SECRET_KEY/SECRET_KEY/" local_settings.py
sed -i -e "s/#GRAPHITE_ROOT.*$/GRAPHITE_ROOT = '\/home\/oracle\/graphite'/" local_settings.py

cat >> local_settings.py<<EOF
DATABASES = {
    'default': {
	'NAME': '/home/oracle/graphite/storage/graphite.db',
	'ENGINE': 'django.db.backends.sqlite3',
	'USER': '',
	'PASSWORD': '',
	'HOST': '',
	'PORT': ''
    }
}
EOF

# Set up graphite backend datastore

# Credit for making this non-interactive: http://obfuscurity.com/2012/04/Unhelpful-Graphite-Tip-4
# Ref: https://docs.djangoproject.com/en/dev/howto/initial-data/

# Create the initial_data.json file, holding our superuser details 
# (extracted from a manual install using django-admin.py dumpdata auth.User)
# Login : oracle / Password01
# (the backslash before the EOF means the special characters in the password hash etc are treated as literals)
cat>/home/oracle/graphite/lib/initial_data.json<<\EOF
[{"pk": 1, "model": "auth.user", "fields": {"username": "oracle", "first_name": "", "last_name": "", "is_active": true, "is_superuser": true, "is_staff": true, "last_login": "2014-03-19T09:22:11.263", "groups": [], "user_permissions": [], "password": "pbkdf2_sha256$12000$jFHXs0bYKO00$IvHMuDUdsvuRxWqaAuXPAhcB/FG4NTBdrVspsyWe5h8=", "email": "", "date_joined": "2014-03-13T21:07:14.276"}}, {"pk": 2, "model": "auth.user", "fields": {"username": "default", "first_name": "", "last_name": "", "is_active": true, "is_superuser": false, "is_staff": false, "last_login": "2014-03-13T21:16:37.958", "groups": [], "user_permissions": [], "password": "!", "email": "default@localhost.localdomain", "date_joined": "2014-03-13T21:16:37.958"}}]
EOF

# Initalise the database
# The initial_data.json is read from $PWD (or /home/oracle/graphite/lib/python2.6/site-packages/django/contrib/auth/fixtures but that wouldn't be right)
cd /home/oracle/graphite/lib/
PYTHONPATH=/home/oracle/graphite/lib/ /home/oracle/graphite/bin/django-admin.py syncdb --noinput --settings=graphite.settings --verbosity=3

# Start Apache

chmod -R o+rwx /home/oracle/graphite
sudo service httpd restart

echo 'You should now be able to go to one of the following IPs to see the initial graphite web page' 
echo $(ip a|grep inet|grep -v 127.0.0.1|awk '{gsub("/24","");print "http://"$2}')
