#!/bin/sh

# Change Host File Entries
ENTRY="localhost localhost master"
FILE=/etc/hosts
if grep -q "$ENTRY" $FILE; then
  echo "entry already exists"
else
  echo $ENTRY >> /etc/hosts
fi

# Force the generation of various directories that are in the EBS mnt
rm -rf /mnt/openstudio
mkdir -p /mnt/openstudio
chmod 777 /mnt/openstudio

# save some files into the right directory
cp /data/prototype/pat/SimulateDataPoint.rb /mnt/openstudio/
cp /data/prototype/pat/CommunicateResults_Mongo.rb /mnt/openstudio/

# copy over the models needed for mongo
mkdir -p /mnt/openstudio/rails-models
cp /data/prototype/pat/rails-models.zip /mnt/openstudio/rails-models/
cd /mnt/openstudio/rails-models
unzip -o rails-models.zip