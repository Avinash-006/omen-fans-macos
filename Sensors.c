#include "Sensors.h"
#include <math.h>
#include <stdint.h>

struct SMCKeyInfo {
    uint32_t size;
    uint32_t type;
    uint8_t attributes;
};

struct SMCCommand {
    uint32_t key;
    uint8_t version[6];
    uint32_t limits[4];
    struct SMCKeyInfo info;
    uint8_t result;
    uint8_t status;
    uint8_t command;
    uint32_t index;
    uint8_t bytes[32];
};

_Static_assert(sizeof(struct SMCCommand) == 80, "AppleSMC command size");

static int read_smc(io_connect_t connection, struct SMCCommand *input, struct SMCCommand *output) {
    size_t size = sizeof(*output);
    return IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size) == KERN_SUCCESS &&
           size == sizeof(*output) && output->result == 0;
}

double omen_cpu_temperature(io_connect_t *connection) {
    if (!*connection) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!service) return NAN;
        kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
        IOObjectRelease(service);
        if (result != KERN_SUCCESS) return NAN;
    }
    const uint32_t packageKey = 0x54433044; /* TC0D, CPU package temperature */
    struct SMCCommand input = {.key = packageKey, .command = 9};
    struct SMCCommand output = {0};
    if (!read_smc(*connection, &input, &output) || output.info.size != 2 || output.info.type != 0x73703738)
        return NAN;
    input.info.size = output.info.size;
    input.command = 5;
    if (!read_smc(*connection, &input, &output)) return NAN;
    return (int16_t)((uint16_t)output.bytes[0] << 8 | output.bytes[1]) / 256.0;
}
