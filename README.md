# telegraf-armhf-installer
A shell script to aid in installing the telegraf binary distribution for ARMhf architecture from https://portal.influxdata.com/downloads

# How to use this script:
~~~~
curl -H 'Accept: application/vnd.github.v3.raw' https://api.github.com/repos/vhsjwp01/telegraf-armhf-installer/contents/telegraf-arm-installer.sh -s | bash
~~~~

NOTES:
* On some systems with systemctl, simply creating the symlink is enough to make systemd think the service is enabled.  However, on some systems this is insufficient
* If ``systemctl start telegraf`` spits an error, run the following command:::
        ``systemctl list-unit-files | egrep telegraf``
        *  if it reports 'linked', then run:::
                ``systemctl enable telegraf``
                ``systemctl start telegraf``

