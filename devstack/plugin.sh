# CloudKitty devstack plugin
# Install and start **CloudKitty** service

# To enable a minimal set of CloudKitty services:
# - enable Ceilometer ;
# - add the following to the [[local|localrc]] section in the local.conf file:
#
#     enable_service ck-api ck-proc
#
# Dependencies:
# - functions
# - OS_AUTH_URL for auth in api
# - DEST, DATA_DIR set to the destination directory
# - SERVICE_PASSWORD, SERVICE_TENANT_NAME for auth in api
# - IDENTITY_API_VERSION for the version of Keystone
# - STACK_USER service user
# - HORIZON_DIR for horizon integration

# stack.sh
# ---------
# install_cloudkitty
# configure_cloudkitty
# init_cloudkitty
# start_cloudkitty
# stop_cloudkitty
# cleanup_cloudkitty
# install_python_cloudkittyclient

# Save trace setting
XTRACE=$(set +o | grep xtrace)
set +o xtrace


# Support potential entry-points console scripts
if [[ -d $CLOUDKITTY_DIR/bin ]]; then
    CLOUDKITTY_BIN_DIR=$CLOUDKITTY_DIR/bin
else
    CLOUDKITTY_BIN_DIR=$(get_python_exec_prefix)
fi

# Functions
# ---------

# create_cloudkitty_accounts() - Set up common required cloudkitty accounts
# Tenant               User          Roles
# ------------------------------------------------------------------
# service              cloudkitty    admin        # if enabled
function create_cloudkitty_accounts {
    create_service_user "cloudkitty"

    local cloudkitty_service=$(get_or_create_service "cloudkitty" \
        "rating" "OpenStack Rating")
    get_or_create_endpoint $cloudkitty_service \
        "$REGION_NAME" \
        "$CLOUDKITTY_SERVICE_PROTOCOL://$CLOUDKITTY_SERVICE_HOSTPORT/" \
        "$CLOUDKITTY_SERVICE_PROTOCOL://$CLOUDKITTY_SERVICE_HOSTPORT/" \
        "$CLOUDKITTY_SERVICE_PROTOCOL://$CLOUDKITTY_SERVICE_HOSTPORT/"

    # Create the rating role
    get_or_create_role "rating"

    # Make cloudkitty an admin
    get_or_add_user_project_role admin cloudkitty service

    # Make CloudKitty monitor demo project for rating purposes
    get_or_add_user_project_role rating cloudkitty demo
}

# Test if any CloudKitty services are enabled
# is_cloudkitty_enabled
function is_cloudkitty_enabled {
    [[ ,${ENABLED_SERVICES} =~ ,"ck-" ]] && return 0
    return 1
}

# Remove WSGI files, disable and remove Apache vhost file
function _cloudkitty_cleanup_apache_wsgi {
    if is_service_enabled ck-api && [ "$CLOUDKITTY_USE_MOD_WSGI" == "True" ]; then
        sudo rm -f "$CLOUDKITTY_WSGI_DIR"/*
        sudo rm -rf  "$CLOUDKITTY_WSGI_DIR"
        sudo rm -f $(apache_site_config_for cloudkitty)
    fi
}

# cleanup_cloudkitty() - Remove residual data files, anything left over from previous
# runs that a clean run would need to clean up
function cleanup_cloudkitty {
    _cloudkitty_cleanup_apache_wsgi
    # Clean up dirs
    rm -rf $CLOUDKITTY_AUTH_CACHE_DIR/*
    rm -rf $CLOUDKITTY_CONF_DIR/*
    rm -rf $CLOUDKITTY_OUTPUT_BASEPATH/*
    for i in $(find $CLOUDKITTY_ENABLED_DIR -iname '_[0-9]*.py' -printf '%f\n'); do
        rm -f "${CLOUDKITTY_HORIZON_ENABLED_DIR}/$i"
    done
}


# Configure mod_wsgi
function _cloudkitty_config_apache_wsgi {
    sudo mkdir -m 755 -p $CLOUDKITTY_WSGI_DIR

    local cloudkitty_apache_conf=$(apache_site_config_for cloudkitty)
    local venv_path=""

    # Copy proxy vhost and wsgi file
    sudo cp $CLOUDKITTY_DIR/cloudkitty/api/app.wsgi $CLOUDKITTY_WSGI_DIR/app.wsgi

    if [[ ${USE_VENV} = True ]]; then
        venv_path="python-path=${PROJECT_VENV["cloudkitty"]}/lib/$(python_version)/site-packages"
    fi

    sudo cp $CLOUDKITTY_DIR/devstack/apache-cloudkitty.template $cloudkitty_apache_conf
    sudo sed -e "
        s|%PORT%|$CLOUDKITTY_SERVICE_PORT|g;
        s|%APACHE_NAME%|$APACHE_NAME|g;
        s|%WSGIAPP%|$CLOUDKITTY_WSGI_DIR/app.wsgi|g;
        s|%USER%|$STACK_USER|g;
        s|%VIRTUALENV%|$venv_path|g
    " -i $cloudkitty_apache_conf
}

# configure_cloudkitty() - Set config files, create data dirs, etc
function configure_cloudkitty {
    setup_develop $CLOUDKITTY_DIR

    sudo mkdir -m 755 -p $CLOUDKITTY_CONF_DIR
    sudo chown $STACK_USER $CLOUDKITTY_CONF_DIR

    sudo mkdir -m 755 -p $CLOUDKITTY_API_LOG_DIR
    sudo chown $STACK_USER $CLOUDKITTY_API_LOG_DIR

    touch $CLOUDKITTY_CONF

    cp $CLOUDKITTY_DIR$CLOUDKITTY_CONF_DIR/policy.json $CLOUDKITTY_CONF_DIR
    cp $CLOUDKITTY_DIR$CLOUDKITTY_CONF_DIR/api_paste.ini $CLOUDKITTY_CONF_DIR
    iniset_rpc_backend cloudkitty $CLOUDKITTY_CONF DEFAULT

    iniset $CLOUDKITTY_CONF DEFAULT notification_topics 'notifications'
    iniset $CLOUDKITTY_CONF DEFAULT debug "$ENABLE_DEBUG_LOG_LEVEL"
    iniset $CLOUDKITTY_CONF DEFAULT auth_strategy $CLOUDKITTY_AUTH_STRATEGY

    # auth
    iniset $CLOUDKITTY_CONF authinfos auth_type v3password
    iniset $CLOUDKITTY_CONF authinfos auth_protocol http
    iniset $CLOUDKITTY_CONF authinfos auth_url "$KEYSTONE_SERVICE_URI/v3"
    iniset $CLOUDKITTY_CONF authinfos identity_uri "$KEYSTONE_SERVICE_URI/v3"
    iniset $CLOUDKITTY_CONF authinfos username cloudkitty
    iniset $CLOUDKITTY_CONF authinfos password $SERVICE_PASSWORD
    iniset $CLOUDKITTY_CONF authinfos project_name $SERVICE_TENANT_NAME
    iniset $CLOUDKITTY_CONF authinfos tenant_name $SERVICE_TENANT_NAME
    iniset $CLOUDKITTY_CONF authinfos region_name $REGION_NAME
    iniset $CLOUDKITTY_CONF authinfos user_domain_name default
    iniset $CLOUDKITTY_CONF authinfos project_domain_name default
    iniset $CLOUDKITTY_CONF authinfos debug "$ENABLE_DEBUG_LOG_LEVEL"

    iniset $CLOUDKITTY_CONF keystone_fetcher auth_section authinfos
    iniset $CLOUDKITTY_CONF keystone_fetcher keystone_version 3

    # collect
    iniset $CLOUDKITTY_CONF collect collector $CLOUDKITTY_COLLECTOR
    iniset $CLOUDKITTY_CONF ${CLOUDKITTY_COLLECTOR}_collector auth_section authinfos
    iniset $CLOUDKITTY_CONF collect services $CLOUDKITTY_SERVICES

    # output
    iniset $CLOUDKITTY_CONF output backend $CLOUDKITTY_OUTPUT_BACKEND
    iniset $CLOUDKITTY_CONF output basepath $CLOUDKITTY_OUTPUT_BASEPATH
    iniset $CLOUDKITTY_CONF output pipeline $CLOUDKITTY_OUTPUT_PIPELINE

    # database
    local dburl=`database_connection_url cloudkitty`
    iniset $CLOUDKITTY_CONF database connection $dburl

    # keystone middleware
    configure_auth_token_middleware $CLOUDKITTY_CONF cloudkitty $CLOUDKITTY_AUTH_CACHE_DIR

    if is_service_enabled ck-api && [ "$CLOUDKITTY_USE_MOD_WSGI" == "True" ]; then
        _cloudkitty_config_apache_wsgi
    fi
}

# create_cloudkitty_cache_dir() - Part of the init_cloudkitty() process
function create_cloudkitty_cache_dir {
    # Create cache dir
    sudo mkdir -p $CLOUDKITTY_AUTH_CACHE_DIR/api
    sudo chown $STACK_USER $CLOUDKITTY_AUTH_CACHE_DIR/api
    rm -f $CLOUDKITTY_AUTH_CACHE_DIR/api/*
    sudo mkdir -p $CLOUDKITTY_AUTH_CACHE_DIR/registry
    sudo chown $STACK_USER $CLOUDKITTY_AUTH_CACHE_DIR/registry
    rm -f $CLOUDKITTY_AUTH_CACHE_DIR/registry/*
}

# create_cloudkitty_data_dir() - Part of the init_cloudkitty() process
function create_cloudkitty_data_dir {
    # Create data dir
    sudo mkdir -p $CLOUDKITTY_DATA_DIR
    sudo chown $STACK_USER $CLOUDKITTY_DATA_DIR
    rm -rf $CLOUDKITTY_DATA_DIR/*
    # Create locks dir
    sudo mkdir -p $CLOUDKITTY_DATA_DIR/locks
    sudo chown $STACK_USER $CLOUDKITTY_DATA_DIR/locks
}

# init_cloudkitty() - Initialize CloudKitty database
function init_cloudkitty {
    # Delete existing cache
    sudo rm -rf $CLOUDKITTY_AUTH_CACHE_DIR
    sudo mkdir -p $CLOUDKITTY_AUTH_CACHE_DIR
    sudo chown $STACK_USER $CLOUDKITTY_AUTH_CACHE_DIR

    # Delete existing cache
    sudo rm -rf $CLOUDKITTY_OUTPUT_BASEPATH
    sudo mkdir -p $CLOUDKITTY_OUTPUT_BASEPATH
    sudo chown $STACK_USER $CLOUDKITTY_OUTPUT_BASEPATH

    # (Re)create cloudkitty database
    recreate_database cloudkitty utf8

    # Migrate cloudkitty database
    $CLOUDKITTY_BIN_DIR/cloudkitty-dbsync upgrade

    # Init the storage backend
    $CLOUDKITTY_BIN_DIR/cloudkitty-storage-init

    create_cloudkitty_cache_dir
    create_cloudkitty_data_dir
}

# install_cloudkitty() - Collect source and prepare
function install_cloudkitty {
    git_clone $CLOUDKITTY_REPO $CLOUDKITTY_DIR $CLOUDKITTY_BRANCH
    setup_develop $CLOUDKITTY_DIR
}

# start_cloudkitty() - Start running processes, including screen
function start_cloudkitty {
    run_process ck-proc "$CLOUDKITTY_BIN_DIR/cloudkitty-processor --config-file=$CLOUDKITTY_CONF"
    if [[ "$CLOUDKITTY_USE_MOD_WSGI" == "False" ]]; then
        run_process ck-api "$CLOUDKITTY_BIN_DIR/cloudkitty-api --config-file=$CLOUDKITTY_CONF"
    elif is_service_enabled ck-api; then
        enable_apache_site cloudkitty
        echo_summary "Waiting 15s for cloudkitty-processor to authenticate against keystone before apache is restarted."
        sleep 15s
        restart_apache_server
        tail_log cloudkitty /var/log/$APACHE_NAME/cloudkitty.log
        tail_log cloudkitty-api /var/log/$APACHE_NAME/cloudkitty_access.log
    fi
    echo "Waiting for ck-api ($CLOUDKITTY_SERVICE_HOST:$CLOUDKITTY_SERVICE_PORT) to start..."
    if ! wait_for_service $SERVICE_TIMEOUT $CLOUDKITTY_SERVICE_PROTOCOL://$CLOUDKITTY_SERVICE_HOST:$CLOUDKITTY_SERVICE_PORT; then
        die $LINENO "ck-api did not start"
    fi
}

# stop_cloudkitty() - Stop running processes
function stop_cloudkitty {
    # Kill the cloudkitty screen windows
    if is_service_enabled ck-proc ; then
        stop_process ck-proc
    fi

    if is_service_enabled ck-api ; then
        if [ "$CLOUDKITTY_USE_MOD_WSGI" == "True" ]; then
            disable_apache_site cloudkitty
            restart_apache_server
        else
            # Kill the cloudkitty screen windows
            stop_process ck-api
        fi
    fi
}

# install_python_cloudkittyclient() - Collect source and prepare
function install_python_cloudkittyclient {
    # Install from git since we don't have a release (yet)
    git_clone_by_name "python-cloudkittyclient"
    setup_dev_lib "python-cloudkittyclient"
}

# install_cloudkitty_dashboard() - Collect source and prepare
function install_cloudkitty_dashboard {
    # Install from git since we don't have a release (yet)
    git_clone_by_name "cloudkitty-dashboard"
    setup_dev_lib "cloudkitty-dashboard"
}

# update_horizon_static() - Update Horizon static files with CloudKitty's one
function update_horizon_static {
    # Code taken from Horizon lib
    # Setup alias for django-admin which could be different depending on distro
    local django_admin
    if type -p django-admin > /dev/null; then
        django_admin=django-admin
    else
        django_admin=django-admin.py
    fi
    DJANGO_SETTINGS_MODULE=openstack_dashboard.settings \
        $django_admin collectstatic --noinput
    DJANGO_SETTINGS_MODULE=openstack_dashboard.settings \
        $django_admin compress --force
    restart_apache_server
}

# configure_cloudkitty_dashboard() - Set config files, create data dirs, etc
function configure_cloudkitty_dashboard {
    sudo ln -s  $CLOUDKITTY_ENABLED_DIR/_[0-9]*.py \
        $CLOUDKITTY_HORIZON_ENABLED_DIR/
    update_horizon_static
}

if is_service_enabled ck-api; then
    if [[ "$1" == "stack" && "$2" == "install" ]]; then
        echo_summary "Installing CloudKitty"
        install_cloudkitty
        install_python_cloudkittyclient
        if is_service_enabled horizon; then
            install_cloudkitty_dashboard
        fi
        cleanup_cloudkitty
    elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        echo_summary "Configuring CloudKitty"
        configure_cloudkitty
        if is_service_enabled horizon; then
            configure_cloudkitty_dashboard
        fi
        if is_service_enabled key; then
            create_cloudkitty_accounts
        fi

    elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
        # Initialize cloudkitty
        echo_summary "Initializing CloudKitty"
        init_cloudkitty

        # Start the CloudKitty API and CloudKitty processor components
        echo_summary "Starting CloudKitty"
        start_cloudkitty
    fi

    if [[ "$1" == "unstack" ]]; then
        stop_cloudkitty
    fi
fi

# Restore xtrace
$XTRACE

# Local variables:
# mode: shell-script
# End:
