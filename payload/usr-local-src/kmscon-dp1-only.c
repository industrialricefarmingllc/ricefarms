#define _GNU_SOURCE
#include <dlfcn.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <stdlib.h>
#include <stdio.h>

static drmModeResPtr (*real_getResources)(int) = NULL;
static drmModeConnectorPtr (*real_getConnector)(int, uint32_t) = NULL;

static void init(void){
    if(!real_getResources) real_getResources = dlsym(RTLD_NEXT, "drmModeGetResources");
    if(!real_getConnector) real_getConnector = dlsym(RTLD_NEXT, "drmModeGetConnector");
}

// Keep resources unfiltered, but fake DP-2/DP-3 as disconnected in getConnector
drmModeResPtr drmModeGetResources(int fd){
    init();
    drmModeResPtr res = real_getResources(fd);
    if(res){
        // Log for debugging but don not filter
        // We keep all connectors so kmscon can see DP-2/DP-3 to disable them
    }
    return res;
}

drmModeConnectorPtr drmModeGetConnector(int fd, uint32_t connectorId){
    init();
    drmModeConnectorPtr c = real_getConnector(fd, connectorId);
    if(!c) return c;
    if(c->connector_type == DRM_MODE_CONNECTOR_DisplayPort && (c->connector_type_id == 2 || c->connector_type_id == 3)){
        // Fake as disconnected so kmscon disables the output (black/off)
        // Do not change connector_id/type, just connection and modes
        if(c->connection == DRM_MODE_CONNECTED){
            fprintf(stderr, "[kmscon-dp1-only] faking DP-%d (id %u) as disconnected (was connected, %d modes)\n", c->connector_type_id, connectorId, c->count_modes);
        }
        c->connection = DRM_MODE_DISCONNECTED;
        c->count_modes = 0;
        // Keep encoder_id 0 to indicate no encoder
        c->encoder_id = 0;
    }
    return c;
}
