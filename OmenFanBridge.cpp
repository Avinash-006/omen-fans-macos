#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <kern/clock.h>
#include <i386/proc_reg.h>
#include <mach/mach_time.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSNumber.h>
#include <mach/kmod.h>

namespace {
constexpr uint32_t leaseMS = 45000;
constexpr uint32_t firmwareHandoffMS = 120000;
constexpr uint8_t minimumPercent = 70;
constexpr uint8_t fanCount = 0x10;
constexpr uint8_t readRPM = 0x2D;
constexpr uint8_t setRPM = 0x2E;
constexpr uint32_t speedWriteFieldSize = 16;
constexpr uint8_t readTable = 0x2F;
constexpr uint8_t biosGuid[] = {
    0x34, 0xF0, 0xB7, 0x5F, 0x63, 0x2C, 0xE9, 0x45,
    0xBE, 0x91, 0x3D, 0x44, 0xE2, 0xC7, 0x07, 0xE4
};
// Only fixed, read-only Intel package DTS registers are exposed.
IOReturn readCPUTemperature(uint64_t *out) {
    uint32_t eax, ebx, ecx, edx;
    __asm__ volatile("cpuid" : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx) : "a"(0), "c"(0));
    if (eax < 6 || ebx != 0x756e6547 || edx != 0x49656e69 || ecx != 0x6c65746e)
        return kIOReturnUnsupported;
    __asm__ volatile("cpuid" : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx) : "a"(6), "c"(0));
    if (!(eax & (1u << 6))) return kIOReturnUnsupported;
    uint32_t high, target, status;
    if (rdmsr_carefully(0x1a2, &target, &high) ||
        rdmsr_carefully(MSR_IA32_PACKAGE_THERM_STATUS, &status, &high)) return kIOReturnUnsupported;
    if (!(status & (1u << 31))) return kIOReturnNotReady;
    const int temperature = static_cast<int>((target >> 16) & 0xff) - static_cast<int>((status >> 16) & 0x7f);
    if (temperature <= 0 || temperature > 125) return kIOReturnNotReady;
    *out = static_cast<uint64_t>(temperature);
    return kIOReturnSuccess;
}

struct Request {
    uint32_t signature = 0x55434553;
    uint32_t command = 0x20008;
    uint32_t query = 0;
    uint32_t inputSize = 0;
    uint8_t bytes[128] = {};
};
static_assert(sizeof(Request) == 144, "HP WMI request layout");
}

class OmenFanBridge final : public IOService {
    OSDeclareDefaultStructors(OmenFanBridge)
    IOACPIPlatformDevice *device = nullptr;
    IOLock *lock = nullptr;
    IOWorkLoop *loop = nullptr;
    IOTimerEventSource *timer = nullptr;
    bool timerAttached = false;
    bool overrideActive = false;
    uint64_t deadline = 0;
    uint64_t handoffUntil = 0;
    char method[5] = {'W', 'M', '\0', '\0', '\0'};
    uint8_t lower[2] = {};
    uint8_t upper[2] = {};
    bool supportedBoard();
    bool findMethod();
    IOReturn query(uint8_t operation, const uint8_t *input, uint32_t inputSize,
                   uint8_t *output = nullptr, uint32_t outputSize = 0);
    IOReturn readCapabilities();
    IOReturn refreshFirmware();
    IOReturn arm(uint32_t milliseconds);
    IOReturn restore();
    static void expired(OSObject *owner, IOTimerEventSource *);
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;
    IOReturn command(uint32_t selector, IOExternalMethodArguments *args);
    void disconnect();
};

class OmenFanClient final : public IOUserClient {
    OSDeclareDefaultStructors(OmenFanClient)
    OmenFanBridge *bridge = nullptr;
    bool ownsBridge = false;
public:
    bool initWithTask(task_t task, void *token, UInt32 type, OSDictionary *properties) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *, OSObject *, void *) override;
};

OSDefineMetaClassAndStructors(OmenFanBridge, IOService)
OSDefineMetaClassAndStructors(OmenFanClient, IOUserClient)

bool OmenFanBridge::supportedBoard() {
    auto table = device->getACPITableData("DSDT");
    if (!table) table = device->getACPITableData("DSDT", 1);
    return table && table->getLength() >= 36 &&
           memcmp(table->getBytesNoCopy(), "DSDT", 4) == 0 &&
           memcmp(static_cast<const uint8_t *>(table->getBytesNoCopy()) + 10,
                  "HPQOEM8BA9    ", 14) == 0;
}

bool OmenFanBridge::findMethod() {
    OSObject *object = nullptr;
    auto result = device->evaluateObject("_WDG", &object);
    auto data = OSDynamicCast(OSData, object);
    bool found = false;
    if (result == kIOReturnSuccess && data && data->getLength() % 20 == 0) {
        auto bytes = static_cast<const uint8_t *>(data->getBytesNoCopy());
        for (unsigned i = 0; i < data->getLength(); i += 20) {
            auto entry = bytes + i;
            if (memcmp(entry, biosGuid, sizeof(biosGuid)) || entry[18] < 1 ||
                !(entry[19] & 2) || (entry[19] & 8)) continue;
            for (unsigned j = 16; j < 18; ++j) {
                auto character = entry[j];
                if (!((character >= 'A' && character <= 'Z') ||
                      (character >= '0' && character <= '9') || character == '_')) break;
                method[j - 14] = static_cast<char>(character);
            }
            found = method[2] && method[3] && device->validateObject(method) == kIOReturnSuccess;
            break;
        }
    }
    if (object) object->release();
    return found;
}

bool OmenFanBridge::start(IOService *provider) {
    if (!IOService::start(provider)) return false;
    device = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!device || strcmp(device->getName(), "WMID") != 0) return false;
    if (!supportedBoard() || !findMethod()) {
        IOLog("OmenFanBridge: HP 8BA9 firmware interface could not be verified\n");
        return false;
    }
    lock = IOLockAlloc();
    loop = IOWorkLoop::workLoop();
    timer = IOTimerEventSource::timerEventSource(this, expired);
    if (!lock || !loop || !timer || loop->addEventSource(timer) != kIOReturnSuccess) return false;
    timerAttached = true;
    registerService();
    return true;
}

void OmenFanBridge::stop(IOService *provider) {
    if (timerAttached) {
        timer->cancelTimeout();
        loop->removeEventSource(timer);
        timerAttached = false;
        IOLockLock(lock);
        restore();
        IOLockUnlock(lock);
    }
    IOService::stop(provider);
}

void OmenFanBridge::free() {
    if (timer) timer->release();
    if (loop) loop->release();
    if (lock) IOLockFree(lock);
    IOService::free();
}

IOReturn OmenFanBridge::query(uint8_t operation, const uint8_t *input, uint32_t inputSize,
                               uint8_t *output, uint32_t outputSize) {
    Request request;
    request.query = operation;
    // BIOS F.26 indexes the ACPI field as a buffer. Older ACPICA evaluates a
    // field of eight bytes or fewer as an integer. Padding leaves both RPM bytes intact.
    request.inputSize = operation == setRPM ? speedWriteFieldSize : inputSize;
    memcpy(request.bytes, input, inputSize);
    const unsigned methodID = outputSize > 4 ? 3 : outputSize ? 2 : 1;
    const unsigned minimumOutput = operation == readTable ? 5 : operation == readRPM ? 2 :
                                   operation == fanCount ? 1 : 0;
    OSObject *params[] = {OSNumber::withNumber(0ULL, 32), OSNumber::withNumber(methodID, 32),
                         OSData::withBytes(&request, sizeof(request))};
    OSObject *object = nullptr;
    IOReturn result = kIOReturnNoMemory;
    if (params[0] && params[1] && params[2]) {
        result = device->evaluateObject(method, &object, params, 3);
        if (result == kIOReturnSuccess) {
            auto data = OSDynamicCast(OSData, object);
            result = kIOReturnIOError;
            if (data && data->getLength() >= 8 + minimumOutput) {
                auto bytes = static_cast<const uint8_t *>(data->getBytesNoCopy());
                if (!(bytes[4] | bytes[5] | bytes[6] | bytes[7])) {
                    if (outputSize) {
                        const unsigned available = data->getLength() - 8;
                        const unsigned count = available < outputSize ? available : outputSize;
                        memset(output, 0, outputSize);
                        memcpy(output, bytes + 8, count);
                    }
                    result = kIOReturnSuccess;
                } else {
                    IOLog("OmenFanBridge: WMI fan query 0x%02x failed (0x%02x)\n", operation, bytes[4]);
                }
            }
        }
    }
    if (object) object->release();
    for (auto param : params) if (param) param->release();
    return result;
}

IOReturn OmenFanBridge::readCapabilities() {
    if (upper[0] && upper[1]) return kIOReturnSuccess;
    const uint8_t input[4] = {};
    uint8_t table[128] = {};
    auto result = query(readTable, input, sizeof(input), table, sizeof(table));
    if (result != kIOReturnSuccess) return result;
    if (table[0] != 2) return kIOReturnUnsupported;
    uint8_t minima[2] = {255, 255};
    uint8_t maxima[2] = {};
    for (unsigned i = 2; i + 2 < sizeof(table); i += 3) {
        if (!(table[i] | table[i + 1] | table[i + 2])) break;
        for (unsigned fan = 0; fan < 2; ++fan) {
            auto speed = table[i + fan];
            if (speed && speed < minima[fan]) minima[fan] = speed;
            if (speed > maxima[fan]) maxima[fan] = speed;
        }
    }
    for (unsigned fan = 0; fan < 2; ++fan) {
        if (maxima[fan] < 20 || maxima[fan] > 100 || minima[fan] > maxima[fan])
            return kIOReturnUnsupported;
    }
    memcpy(lower, minima, sizeof(lower));
    memcpy(upper, maxima, sizeof(upper));
    return kIOReturnSuccess;
}

IOReturn OmenFanBridge::refreshFirmware() {
    uint8_t input = 0;
    uint8_t output[4] = {};
    auto result = query(fanCount, &input, sizeof(input), output, sizeof(output));
    if (result != kIOReturnSuccess) return result;
    return output[0] == 2 ? kIOReturnSuccess : kIOReturnUnsupported;
}

IOReturn OmenFanBridge::arm(uint32_t milliseconds) {
    clock_interval_to_deadline(milliseconds, NSEC_PER_MSEC, &deadline);
    return timer->wakeAtTime(deadline);
}

IOReturn OmenFanBridge::restore() {
    if (!overrideActive) return kIOReturnSuccess;
    timer->cancelTimeout();
    deadline = 0;
    overrideActive = false;

    // On 8BA9 zero is a speed command. Leave the fans cooling at full speed
    // and stop sending the 0x10 keep-alive so firmware can resume its curve.
    const auto result = query(setRPM, upper, sizeof(upper));
    clock_interval_to_deadline(firmwareHandoffMS, NSEC_PER_MSEC, &handoffUntil);
    return result;
}

void OmenFanBridge::expired(OSObject *owner, IOTimerEventSource *) {
    auto bridge = static_cast<OmenFanBridge *>(owner);
    IOLockLock(bridge->lock);
    if (bridge->deadline && mach_absolute_time() >= bridge->deadline) bridge->restore();
    IOLockUnlock(bridge->lock);
}

void OmenFanBridge::disconnect() {
    IOLockLock(lock);
    restore();
    IOLockUnlock(lock);
}

IOReturn OmenFanBridge::command(uint32_t selector, IOExternalMethodArguments *args) {
    IOLockLock(lock);
    IOReturn result = kIOReturnSuccess;
    if (selector == 0) {
        const uint8_t input = 0;
        uint8_t speed[128] = {};
        result = query(readRPM, &input, sizeof(input), speed, sizeof(speed));
        if (result == kIOReturnSuccess) {
            args->scalarOutput[0] = speed[0] * 100;
            args->scalarOutput[1] = speed[1] * 100;
            args->scalarOutput[2] = overrideActive ? 1 : mach_absolute_time() < handoffUntil ? 2 : 0;
            args->scalarOutput[3] = readCapabilities() == kIOReturnSuccess;
        }
    } else if (selector == 1) {
        result = restore();
    } else if (selector == 2) {
        result = readCapabilities();
        if (result == kIOReturnSuccess) result = refreshFirmware();
        if (result == kIOReturnSuccess) {
            uint8_t target[2];
            for (unsigned i = 0; i < 2; ++i) {
                const auto speed = (args->scalarInput[i] * upper[i] + 50) / 100;
                target[i] = static_cast<uint8_t>(speed < lower[i] ? lower[i] : speed);
            }
            overrideActive = true;
            result = query(setRPM, target, sizeof(target));
            if (result == kIOReturnSuccess) result = arm(leaseMS);
        }
        if (result != kIOReturnSuccess) restore();
    } else if (selector == 4) {
        result = readCapabilities();
        if (result == kIOReturnSuccess) {
            args->scalarOutput[0] = upper[0] * 100;
            args->scalarOutput[1] = upper[1] * 100;
        }
    } else if (selector == 5) {
        result = readCPUTemperature(args->scalarOutput);
    } else if (selector == 6) {
        args->scalarOutput[0] = 1;
    } else {
        result = overrideActive ? refreshFirmware() : kIOReturnNotReady;
        if (result == kIOReturnSuccess) result = arm(leaseMS);
        if (result != kIOReturnSuccess) restore();
    }
    IOLockUnlock(lock);
    return result;
}

bool OmenFanClient::initWithTask(task_t task, void *token, UInt32 type, OSDictionary *properties) {
    if (type != 0 || !task ||
        clientHasPrivilege(task, kIOClientPrivilegeLocalUser) != kIOReturnSuccess) return false;
    return IOUserClient::initWithTask(task, token, type, properties);
}

bool OmenFanClient::start(IOService *provider) {
    if (!IOUserClient::start(provider)) return false;
    bridge = OSDynamicCast(OmenFanBridge, provider);
    ownsBridge = bridge && bridge->open(this);
    return ownsBridge;
}

void OmenFanClient::stop(IOService *provider) {
    if (ownsBridge) {
        bridge->disconnect();
        bridge->close(this);
        ownsBridge = false;
    }
    IOUserClient::stop(provider);
}

IOReturn OmenFanClient::clientClose() {
    terminate();
    return kIOReturnSuccess;
}

IOReturn OmenFanClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                                      IOExternalMethodDispatch *, OSObject *, void *) {
    if (!ownsBridge || isInactive()) return kIOReturnNotOpen;
    if (selector > 6) return kIOReturnUnsupported;
    if (args->scalarInputCount != (selector == 2 ? 2u : 0u) ||
        args->scalarOutputCount != (selector == 0 ? 4u : selector == 4 ? 2u : (selector == 5 || selector == 6) ? 1u : 0u) ||
        args->structureInputSize || args->structureOutputSize ||
        args->structureInputDescriptor || args->structureOutputDescriptor || args->asyncWakePort)
        return kIOReturnBadArgument;
    if (selector == 2) {
        for (unsigned i = 0; i < 2; ++i) {
            if (args->scalarInput[i] < minimumPercent || args->scalarInput[i] > 100)
                return kIOReturnBadArgument;
        }
    }
    return bridge->command(selector, args);
}

extern "C" {
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
KMOD_EXPLICIT_DECL(local_omen_fans_bridge, "1.0.3", _start, _stop)
__attribute__((visibility("default"))) kmod_start_func_t *_realmain = nullptr;
__attribute__((visibility("default"))) kmod_stop_func_t *_antimain = nullptr;
__attribute__((visibility("default"))) int _kext_apple_cc = __APPLE_CC__;
}
