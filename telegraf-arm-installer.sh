#!/bin/bash
#set -x

PATH="/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin"
TERM="vt100"
export TERM PATH

SUCCESS=0
ERROR=1

err_msg=""
exit_code=${SUCCESS}

TELEGRAF_DL_URL="https://portal.influxdata.com/downloads#telegraf"
TELEGRAF_REGEX="wget.*telegraf.*armhf.*\.tar\.gz"
TELEGRAF_IGNORE_REGEX="~rc"

# WHAT: Make sure needed commands are present
# WHY:  They will come into play later on in this script
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    needed_commands="awk cpio curl egrep elinks find id tar zcat"

    for needed_command in ${needed_commands} ; do
        command_found=$(unalias "${needed_command}" > /dev/null 2>&1 ; which "${needed_command}" 2> /dev/null)
    
        if [ "${command_found}" = "" ]; then
            err_msg="The command \"${needed_command}\" is required and could not be located"
            exit_code=${ERROR}
            break
        fi
    
    done

fi

# WHAT: Make sure we are root
# WHY:  Privileges are required to install from binary source
#
if [ ${exit_code} -eq ${SUCCESS} ]; then

    if [ $(id -u) -ne 0 ]; then
        err_msg="You must be root to run this script"
        exit_code=${ERROR}
    fi

fi

# WHAT: Figure out our fetch command from the vendor download URL and download the software archive
# WHY:  If successful, we will be unpacking and then installing the software
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    fetch_command=$(curl ${TELEGRAF_DL_URL} -s | elinks -dump | egrep "${TELEGRAF_REGEX}" | egrep -v "${TELEGRAF_IGNORE_REGEX}")

    if [ "${fetch_command}" = "" ]; then
        err_msg="Failed to discern fetch command from the URL: \"${TELEGRAF_DL_URL}\""
        exit_code=${ERROR}
    else
        target_filename=$(echo "${fetch_command}" | awk -F'/' '{print $NF}')
        eval "${fetch_command}" > /dev/null 2>&1
        exit_code=${?}

        if [ ${exit_code} -ne ${SUCCESS} ]; then
            err_msg="Execution of command \"${fetch_command}\" failed"
        else

            if [ ! -e "${target_filename}" ]; then
                err_msg="Fetching reported success, but payload \"${target_filename}\" is not present"
                exit_code=${ERROR}
            fi

        fi

    fi

fi

# WHAT: Unpack this archive and set permissions to something sane
# WHY:  Historically, permissions have been chaotic at times
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    target_folder_name=$(gzcat "${target_filename}" | tar xvf - 2>&1 | awk -F'/' '/x \.\// {print $2}' | sort -u)
    #echo "Target folder name: \"${target_folder_name}\""
    telegraf_version=$(echo "${target_filename}" | sed -e 's?\.tar\.gz$??g' | sed -e "s#^${target_folder_name}-##g")
    #echo "Telegraf version: ${telegraf_version}"

    # Make sure the target folder exists
    if [ -d "./${target_folder_name}" ]; then

        # See if the name contains the version
        let version_check=$(echo "${target_folder_name}" | egrep -c "${telegraf_version}")

        # Rename the folder to include the version if missing
        if [ ${version_check} -eq 0 ]; then
            mv "${target_folder_name}" "${target_folder_name}-${telegraf_version}"
            target_folder_name="${target_folder_name}-${telegraf_version}"
        fi

    else
        err_msg="Archive folder \"${target_folder_name}\" was not created"
        exit_code=${ERROR}
    fi

    #echo "Target folder name: \"${target_folder_name}\""
fi

# WHAT: Fix folder permissions
# WHY:  They may not be what they need to be following unpacking of the archive
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    chown -R root:root "${target_folder_name}"
    exit_code=${?}

    if [ ${exit_code} -ne ${SUCCESS} ]; then
        err_msg="Failed to change ownership of \"${target_folder_name}\" to root:root"
    fi
    
fi

# WHAT: Check for telegraf user and create it if missing
# WHY:  Needed for running the daemon
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    telegraf_user="telegraf"
    id -u ${telegraf_user} 2> /dev/null
    status_code=${?}

    # Create the user if the id command fails
    if [ ${status_code} -ne ${SUCCESS} ]; then
        useradd -m ${telegraf_user}
        exit_code=${?}

        if [ ${exit_code} -ne ${SUCCESS} ]; then
            err_msg="Failed to create daemon account \"${telegraf_user}\""
        fi

    fi

fi

# WHAT: Assign daemon account permissions to sub folders
# WHY:  Needed once the service is active
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    chown -R ${telegraf_user}:${telegraf_user} ${target_folder_name}/var/log/telegraf
    exit_code=${?}

    if [ ${exit_code} -ne ${SUCCESS} ]; then
        err_msg="Failed to set sub folder permissions for daemon account \"${telegraf_user}\" under installation folder \"${target_folder_name}\""
    fi

fi

# WHAT: Relocate installation folder items to the root of the file system
# WHY:  Installation prep is complete
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    cd "${target_folder_name}" && find . -depth -print | cpio -pdm / > /dev/null 2>&1
    exit_code=${?}

    if [ ${exit_code} -ne ${SUCCESS} ]; then
        err_msg="Failed to copy installation targets to their final destination"
    fi

fi

# WHAT: Install service init items
# WHY:  So the service can be controlled natively
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    service_scripts_folder="/usr/lib/telegraf/scripts"
    systemctl_or_init=$(which systemctl 2> /dev/null)

    case ${systemctl_or_init} in

        systemctl)
            service_activation_folder="/etc/systemd/system"
            service_file=$(find "${service_scripts_folder}" -maxdepth 1 -type f -iname "telegraf.service")
            service_file_basename=$(basename "${service_file}")
            service_location_folder=$(find "${service_activation_folder}" -maxdepth 1 -type l -exec dirname '{}' \; | sort -u)
            initialize_command="ln -s \"${service_file}\" \"${service_location_folder}/${service_file_basename}\""
            enable_command="ln -s \"${service_location_folder}/${service_file_basename}\" \"${service_activation_folder}/${service_file_basename}\""
            start_command="systemctl start ${service_file_basename}"
        ;;

        *)
            service_activation_folder="/etc/init.d"
            service_file=$(find "${service_scripts_folder}" -maxdepth 1 -type f -iname "init.sh")
            initialize_command="ln -s \"${service_file}\" \"${service_activation_folder}/telegraf\""
            enable_command="update-rc.d telegraf defaults && update-rc.d telegraf enable"
            start_command="service telegraf start"
        ;;

    esac

    if [ "${initialize_command}" != "" -a "${enable_command}" != "" -a "${start_command}" != "" ]; then
        eval "${initialize_command}"
        exit_code=${?}

        if [ ${exit_code} -eq ${SUCCESS} ]; then
            echo "Telegraf is installed, but not configured for your environment."
            echo "To configure telegraf, make changes to the file \"/etc/telegraf/telegraf.conf\""
            echo 
            echo "To enable telegraf, run the following command:"
            echo "    sudo ${enable_command}"
            echo 
            echo "To start telegraf, run the following command:"
            echo "    sudo ${start_command}"
            echo
        else
            err_msg="Initialization command \"${initialize_command}\" failed"
        fi

    else
        err_msg="Service initialization command detection failed"
        exit_code=${ERROR}
    fi

fi

# WHAT: Complain, if possible, then exit
# WHY:  Success or failure, either way we are through!
#
if [ ${exit_code} -ne ${SUCCESS} ]; then

    if [ "${err_msg}" != "" ]; then
        echo "    ERROR:  ${err_msg} ... processing halted"
    fi

fi

exit ${exit_code}