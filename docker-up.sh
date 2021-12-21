#!/bin/sh

set -e
#echo "in UP.sh >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"-e url=https://www.qcguy.com
#./build.sh

docker run --restart=always --network 5million -d --name qcguy -p 2368:2368 -v /home/vik/IdeaProjects/qcguy-cms/config/config.production.json:/var/lib/ghost/config.production.json -v some-ghost-data:/var/lib/ghost/content ghost