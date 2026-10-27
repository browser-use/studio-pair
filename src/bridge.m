#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <AudioToolbox/AudioToolbox.h>
#include <libproc.h>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>
#include <math.h>

typedef struct {
    UInt32 id, channels, mute, running;
    Float32 volume;
    Float64 rate;
    char uid[512];
} SPDevice;
typedef struct {
    AudioObjectID tap, aggregate;
    AudioObjectID a, b;
    AudioDeviceIOProcID proc;
    void *description;
    bool started;
} SPPair;
static char errorText[512];
const char *sp_error(void) { return errorText; }
static bool fail(const char *operation, OSStatus status) {
    snprintf(errorText, sizeof(errorText), "%s (%d)", operation, (int)status); return false;
}
static AudioObjectPropertyAddress addr(UInt32 sel, UInt32 scope) {
    return (AudioObjectPropertyAddress){sel,scope,kAudioObjectPropertyElementMain};
}
static OSStatus readp(AudioObjectID id, UInt32 sel, UInt32 scope, void *out, UInt32 size) {
    AudioObjectPropertyAddress a=addr(sel,scope);
    return AudioObjectGetPropertyData(id,&a,0,NULL,&size,out);
}
static OSStatus writep(AudioObjectID id, UInt32 sel, UInt32 scope, const void *in, UInt32 size) {
    AudioObjectPropertyAddress a=addr(sel,scope);
    return AudioObjectSetPropertyData(id,&a,0,NULL,size,in);
}
static NSArray<NSNumber *> *ids(AudioObjectID id, UInt32 sel, UInt32 scope) {
    AudioObjectPropertyAddress a=addr(sel,scope); UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(id,&a,0,NULL,&size) || size>65536) return @[];
    UInt32 *values=calloc(1,MAX(size,4));
    OSStatus s=AudioObjectGetPropertyData(id,&a,0,NULL,&size,values);
    NSMutableArray *out=[NSMutableArray array];
    if(!s) for(UInt32 i=0;i<size/4;i++) [out addObject:@(values[i])];
    free(values); return out;
}
static NSString *stringp(AudioObjectID id, UInt32 sel) {
    CFStringRef value=NULL;
    if(readp(id,sel,kAudioObjectPropertyScopeGlobal,&value,sizeof(value)) || !value) return @"";
    return CFBridgingRelease(value);
}
static UInt32 channelCount(AudioObjectID id, UInt32 scope) {
    AudioObjectPropertyAddress a=addr(kAudioDevicePropertyStreamConfiguration,scope); UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(id,&a,0,NULL,&size) || size>65536) return 0;
    AudioBufferList *b=calloc(1,MAX(size,8));
    OSStatus s=AudioObjectGetPropertyData(id,&a,0,NULL,&size,b); UInt32 count=0;
    if(!s && size>=offsetof(AudioBufferList,mBuffers) && b->mNumberBuffers<=64 &&
       offsetof(AudioBufferList,mBuffers)+b->mNumberBuffers*sizeof(AudioBuffer)<=size)
        for(UInt32 i=0;i<b->mNumberBuffers;i++) count+=b->mBuffers[i].mNumberChannels;
    free(b); return count;
}
UInt32 sp_default_output(void) {
    UInt32 id=0; readp(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,&id,sizeof(id)); return id;
}
int sp_device(UInt32 id, SPDevice *d) {
    memset(d,0,sizeof(*d)); d->id=id;
    NSString *uid=stringp(id,kAudioDevicePropertyDeviceUID);
    if(!uid.length) return fail("Device disappeared",-1);
    snprintf(d->uid,sizeof(d->uid),"%s",uid.UTF8String);
    d->channels=channelCount(id,kAudioDevicePropertyScopeOutput);
    if(readp(id,kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,&d->rate,sizeof(d->rate)) ||
       readp(id,kAudioDevicePropertyVolumeScalar,kAudioObjectPropertyScopeOutput,&d->volume,sizeof(d->volume)) ||
       readp(id,kAudioDevicePropertyMute,kAudioObjectPropertyScopeOutput,&d->mute,sizeof(d->mute))) return fail("Cannot read hardware controls",-1);
    readp(id,kAudioDevicePropertyDeviceIsRunningSomewhere,kAudioObjectPropertyScopeGlobal,&d->running,sizeof(d->running));
    return isfinite(d->volume) && d->volume>=0 && d->volume<=1;
}
int sp_displays(SPDevice *out, int capacity) {
    @autoreleasepool {
        int n=0;
        for(NSNumber *number in ids(kAudioObjectSystemObject,kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal)) {
            UInt32 id=number.unsignedIntValue;
            if([stringp(id,kAudioObjectPropertyName) isEqualToString:@"Studio Display Speakers"] && channelCount(id,kAudioDevicePropertyScopeOutput)>0) {
                if(n<capacity && !sp_device(id,&out[n])) return -1; n++;
            }
        }
        return n;
    }
}
static NSString *processPath(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE]={0}; proc_pidpath(pid,path,sizeof(path)); return @(path);
}
static NSString *processBirth(pid_t pid) {
    struct proc_bsdinfo info={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info))return nil;
    return [NSString stringWithFormat:@"%llu:%llu",info.pbi_start_tvsec,info.pbi_start_tvusec];
}
static bool journalProcessIsLive(NSDictionary *j) {
    pid_t pid=[j[@"pid"] intValue];
    return pid>1 && pid!=getpid() && [processPath(pid) isEqualToString:j[@"executable"]] &&
        [processBirth(pid) isEqualToString:j[@"process_birth"]];
}
static NSArray<NSNumber *> *processes(const char *bundle, pid_t pid, UInt32 anchor) {
    NSMutableArray *found=[NSMutableArray array];
    for(NSNumber *n in ids(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal)) {
        AudioObjectID id=n.unsignedIntValue; pid_t p=0;
        readp(id,kAudioProcessPropertyPID,kAudioObjectPropertyScopeGlobal,&p,sizeof(p));
        NSString *bid=stringp(id,kAudioProcessPropertyBundleID);
        bool matches=pid>0 ? p==pid : ([bid isEqualToString:@(bundle)] || [bid hasPrefix:[@(bundle) stringByAppendingString:@"."]]);
        if(!matches || p==getpid()) continue;
        NSArray *devices=ids(id,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeGlobal);
        if(devices.count && ![devices containsObject:@(anchor)]) continue;
        [found addObject:n];
    }
    return found;
}
void sp_inspect(void) {
    @autoreleasepool {
        NSMutableArray *dev=[NSMutableArray array], *procs=[NSMutableArray array];
        SPDevice d[8]; int n=sp_displays(d,8);
        for(int i=0;i<MIN(n,8);i++) [dev addObject:@{@"id":@(d[i].id),@"uid":@(d[i].uid),@"channels":@(d[i].channels),@"volume":@(d[i].volume),@"mute":@(d[i].mute),@"rate":@(d[i].rate),@"running":@(d[i].running)}];
        for(NSNumber *num in ids(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList,kAudioObjectPropertyScopeGlobal)) {
            UInt32 id=num.unsignedIntValue, running=0; pid_t pid=0;
            readp(id,kAudioProcessPropertyPID,kAudioObjectPropertyScopeGlobal,&pid,sizeof(pid));
            readp(id,kAudioProcessPropertyIsRunningOutput,kAudioObjectPropertyScopeGlobal,&running,sizeof(running));
            [procs addObject:@{@"id":num,@"pid":@(pid),@"bundle":stringp(id,kAudioProcessPropertyBundleID),@"running":@(running),@"devices":ids(id,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeGlobal)}];
        }
        UInt32 in=0,sys=0; readp(1,kAudioHardwarePropertyDefaultInputDevice,kAudioObjectPropertyScopeGlobal,&in,4); readp(1,kAudioHardwarePropertyDefaultSystemOutputDevice,kAudioObjectPropertyScopeGlobal,&sys,4);
        NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"default_output":@(sp_default_output()),@"default_input":@(in),@"default_system_output":@(sys),@"displays":dev,@"processes":procs} options:NSJSONWritingPrettyPrinted error:nil];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
}
static bool validateStreams(UInt32 device, UInt32 scope, double rate) {
    for(NSNumber *n in ids(device,kAudioDevicePropertyStreams,scope)) {
        AudioStreamBasicDescription f={0};
        if(readp(n.unsignedIntValue,kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal,&f,sizeof(f)) ||
           f.mFormatID!=kAudioFormatLinearPCM || !(f.mFormatFlags&kAudioFormatFlagIsFloat) || f.mBitsPerChannel!=32 ||
           (f.mFormatFlags&kAudioFormatFlagIsBigEndian) || fabs(f.mSampleRate-rate)>0.1)
            return fail("Expected native Float32 at unchanged sample rate",-1);
    }
    return true;
}
SPPair *sp_create(UInt32 a, UInt32 b, const char *bundle, int pid) {
    @autoreleasepool {
        SPDevice da,db;
        if(!sp_device(a,&da)||!sp_device(b,&db)) return NULL;
        if(da.channels!=8||db.channels!=8||fabs(da.rate-db.rate)>0.1||fabs(da.rate-48000)>0.1) { fail("Pairing requires two 8-channel displays already at 48 kHz",-1); return NULL; }
        NSArray *ps=processes(bundle,pid,sp_default_output());
        if(!ps.count) { fail("No source audio process on the current Studio Display; start playback first",-1); return NULL; }
        SPPair *p=calloc(1,sizeof(SPPair));
        p->a=a;p->b=b;
        CATapDescription *desc=[[CATapDescription alloc] initWithProcesses:ps andDeviceUID:@(da.uid) withStream:0];
        desc.name=@"Studio Pair temporary music tap";
        desc.UUID=[NSUUID UUID]; desc.privateTap=YES; desc.muteBehavior=CATapUnmuted;
        desc.deviceUID=stringp(sp_default_output(),kAudioDevicePropertyDeviceUID); desc.stream=@0;
        OSStatus s=AudioHardwareCreateProcessTap(desc,&p->tap);
        if(s) {fail("Create audio tap",s);free(p);return NULL;}
        p->description=(__bridge_retained void *)desc;
        NSDictionary *description=@{
            @kAudioAggregateDeviceNameKey:@"Studio Pair temporary private route",
            @kAudioAggregateDeviceUIDKey:[@"com.browseruse.studiopair." stringByAppendingString:desc.UUID.UUIDString],
            @kAudioAggregateDeviceMainSubDeviceKey:@(da.uid),
            @kAudioAggregateDeviceIsPrivateKey:@1,
            // Observed on this Mac: 0 exposes both eight-channel streams; 1 mirrors stereo.
            @kAudioAggregateDeviceIsStackedKey:@0,
            @kAudioAggregateDeviceTapAutoStartKey:@1,
            @kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:@(da.uid),@kAudioSubDeviceDriftCompensationKey:@0},@{@kAudioSubDeviceUIDKey:@(db.uid),@kAudioSubDeviceDriftCompensationKey:@1}],
            @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:desc.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@1}]
        };
        s=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description,&p->aggregate);
        if(s) {fail("Create private aggregate",s); AudioHardwareDestroyProcessTap(p->tap); CFBridgingRelease(p->description);free(p);return NULL;}
        return p;
    }
}
int sp_validate(SPPair *p) {
    @autoreleasepool {
    CFDictionaryRef raw=NULL;
    if(readp(p->aggregate,kAudioAggregateDevicePropertyComposition,kAudioObjectPropertyScopeGlobal,&raw,sizeof(raw)) || !raw)
        return fail("Cannot verify private aggregate configuration",-1);
    NSDictionary *config=CFBridgingRelease(raw);
    NSArray *subs=config[@kAudioAggregateDeviceSubDeviceListKey];
    if(subs.count!=2 || ![subs[0][@kAudioSubDeviceUIDKey] isEqualToString:stringp(p->a,kAudioDevicePropertyDeviceUID)] ||
       ![subs[1][@kAudioSubDeviceUIDKey] isEqualToString:stringp(p->b,kAudioDevicePropertyDeviceUID)] ||
       [subs[0][@kAudioSubDeviceDriftCompensationKey] intValue]!=0 || [subs[1][@kAudioSubDeviceDriftCompensationKey] intValue]!=1 ||
       [config[@kAudioAggregateDeviceIsStackedKey] intValue]!=0 || [config[@kAudioAggregateDeviceIsPrivateKey] intValue]!=1)
        return fail("Aggregate order, isolation, or clock correction did not match",-1);
    AudioStreamBasicDescription f={0};
    if(readp(p->tap,kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal,&f,sizeof(f))) return fail("Read tap format",-1);
    if(f.mFormatID!=kAudioFormatLinearPCM || !(f.mFormatFlags&kAudioFormatFlagIsFloat) || f.mBitsPerChannel!=32 || f.mChannelsPerFrame!=8 || fabs(f.mSampleRate-48000)>0.1)
        return fail("Tap did not provide native eight-channel Float32 at 48 kHz",-1);
    UInt32 out=channelCount(p->aggregate,kAudioObjectPropertyScopeOutput), in=channelCount(p->aggregate,kAudioObjectPropertyScopeInput);
    if(out!=16 || in!=8) {snprintf(errorText,sizeof(errorText),"Aggregate has %u input and %u output channels; expected 8 and 16",in,out);return 0;}
    return validateStreams(p->aggregate,kAudioObjectPropertyScopeOutput,48000) && validateStreams(p->aggregate,kAudioObjectPropertyScopeInput,48000);
    }
}
int sp_tap_mute(SPPair *p, int mode) {
    @autoreleasepool {
        CATapDescription *desc=(__bridge CATapDescription *)p->description;
        desc.muteBehavior=(CATapMuteBehavior)mode;
        CATapDescription *value=desc;
        OSStatus s=writep(p->tap,kAudioTapPropertyDescription,kAudioObjectPropertyScopeGlobal,&value,sizeof(value));
        return s ? fail("Change tap handoff",s) : 1;
    }
}
int sp_start(SPPair *p, AudioDeviceIOProc callback, void *context) {
    OSStatus s=AudioDeviceCreateIOProcID(p->aggregate,callback,context,&p->proc);
    if(s)return fail("Create IO callback",s);
    s=AudioDeviceStart(p->aggregate,p->proc);
    if(s)return fail("Start private audio route",s);
    p->started=true;return 1;
}
void sp_destroy(SPPair *p) {
    if(!p)return;
    if(p->tap)sp_tap_mute(p,0);
    if(p->started)AudioDeviceStop(p->aggregate,p->proc);
    if(p->proc)AudioDeviceDestroyIOProcID(p->aggregate,p->proc);
    if(p->aggregate)AudioHardwareDestroyAggregateDevice(p->aggregate);
    if(p->tap)AudioHardwareDestroyProcessTap(p->tap);
    if(p->description)CFBridgingRelease(p->description);
    free(p);
}
// Hardware-control journal is written before any secondary-volume mutation.
static NSMutableDictionary *journal;
static NSString *journalPath;
static bool saveJournal(void) {
    NSData *d=[NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingPrettyPrinted error:nil];
    bool ok=[d writeToFile:journalPath options:NSDataWritingAtomic error:nil];
    if(ok)chmod(journalPath.fileSystemRepresentation,0600);
    return ok ? true : fail("Save rollback journal",-1);
}
int sp_journal_begin(const char *path,UInt32 secondary) {
    @autoreleasepool {
        SPDevice d;if(!sp_device(secondary,&d))return 0;
        journalPath=@(path);
        journal=[@{@"pid":@(getpid()),@"executable":processPath(getpid()),@"secondary_uid":@(d.uid),@"original_volume":@(d.volume),@"original_mute":@(d.mute),@"last_volume":@(d.volume),@"last_mute":@(d.mute),@"volume_written":@NO,@"mute_written":@NO,@"restored":@NO} mutableCopy];
        NSString *birth=processBirth(getpid());
        if(!birth)return fail("Cannot identify worker for safe recovery",-1);
        journal[@"process_birth"]=birth;
        return saveJournal();
    }
}
int sp_sync_volume(UInt32 anchor,UInt32 secondary) {
    @autoreleasepool {
        SPDevice a,b;if(!sp_device(anchor,&a)||!sp_device(secondary,&b))return 0;
        if(fabs(a.rate-48000)>0.1||fabs(b.rate-48000)>0.1)return fail("Display sample rate changed; returning to direct playback",-1);
        if(fabsf(a.volume-b.volume)>0.0001) {
            journal[@"last_volume"]=@(a.volume);journal[@"volume_written"]=@YES;if(!saveJournal())return 0;
            OSStatus s=writep(secondary,kAudioDevicePropertyVolumeScalar,kAudioObjectPropertyScopeOutput,&a.volume,sizeof(a.volume));
            if(s)return fail("Sync secondary volume",s);
        }
        if(a.mute!=b.mute) {
            journal[@"last_mute"]=@(a.mute);journal[@"mute_written"]=@YES;if(!saveJournal())return 0;
            OSStatus s=writep(secondary,kAudioDevicePropertyMute,kAudioObjectPropertyScopeOutput,&a.mute,sizeof(a.mute));
            if(s)return fail("Sync secondary mute",s);
        }
        return 1;
    }
}
int sp_restore(const char *path, int stopWorker) {
    @autoreleasepool {
        NSData *data=[NSData dataWithContentsOfFile:@(path)];
        if(!data)return 1;
        id parsed=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if(![parsed isKindOfClass:[NSDictionary class]])return fail("Invalid rollback journal",-1);
        NSMutableDictionary *j=[parsed mutableCopy];
        if([j[@"restored"] boolValue])return 1;
        pid_t pid=[j[@"pid"] intValue];
        if(!j[@"process_birth"] && pid>1 && pid!=getpid() && [processPath(pid) isEqualToString:j[@"executable"]])
            return fail("Legacy worker identity is incomplete; quit the old app before recovery",-1);
        bool live=journalProcessIsLive(j);
        if(live && !stopWorker)return fail("Worker is still running",-1);
        if(live) {
            kill(pid,SIGTERM);
            for(int i=0;i<30 && journalProcessIsLive(j);i++)usleep(100000);
            if(journalProcessIsLive(j))kill(pid,SIGKILL);
            for(int i=0;i<20 && journalProcessIsLive(j);i++)usleep(100000);
            if(journalProcessIsLive(j))return fail("Worker did not stop; hardware restore postponed",-1);
            data=[NSData dataWithContentsOfFile:@(path)];j=[[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] mutableCopy];
            if(![j isKindOfClass:[NSDictionary class]])return fail("Invalid rollback journal after stop",-1);
        }
        if([j[@"restored"] boolValue])return 1;
        UInt32 device=0;
        for(NSNumber *n in ids(1,kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal))
            if([stringp(n.unsignedIntValue,kAudioDevicePropertyDeviceUID) isEqualToString:j[@"secondary_uid"]]) device=n.unsignedIntValue;
        if(!device && ([j[@"volume_written"] boolValue] || [j[@"mute_written"] boolValue]))
            return fail("Reconnect the second display, then use Stop to finish volume restoration",-1);
        if(device && sp_default_output()!=device) {
            SPDevice d;if(!sp_device(device,&d))return 0;
            if([j[@"volume_written"] boolValue] && fabsf(d.volume-[j[@"last_volume"] floatValue])<0.0002) {
                Float32 v=[j[@"original_volume"] floatValue];
                if(!isfinite(v)||v<0||v>1)return fail("Invalid saved volume",-1);
                OSStatus s=writep(device,kAudioDevicePropertyVolumeScalar,kAudioObjectPropertyScopeOutput,&v,sizeof(v));
                if(s)return fail("Restore secondary volume",s);
            }
            if([j[@"mute_written"] boolValue] && d.mute==[j[@"last_mute"] unsignedIntValue]) {
                UInt32 mute=[j[@"original_mute"] unsignedIntValue];
                OSStatus s=writep(device,kAudioDevicePropertyMute,kAudioObjectPropertyScopeOutput,&mute,sizeof(mute));
                if(s)return fail("Restore secondary mute",s);
            }
        }
        j[@"restored"]=@YES;
        NSData *saved=[NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:nil];
        bool ok=[saved writeToFile:@(path) options:NSDataWritingAtomic error:nil];
        if(ok)chmod(path,0600);
        return ok ? 1 : fail("Save completed rollback",-1);
    }
}
// A short identification tone opens an existing output only. It never sets defaults.
typedef struct { AudioObjectID device; AudioDeviceIOProcID proc; } SPTone;
SPTone *sp_tone_start(UInt32 device, AudioDeviceIOProc callback, void *context) {
    if(!validateStreams(device,kAudioObjectPropertyScopeOutput,48000))return NULL;
    SPTone *t=calloc(1,sizeof(SPTone));t->device=device;
    OSStatus s=AudioDeviceCreateIOProcID(device,callback,context,&t->proc);
    if(!s)s=AudioDeviceStart(device,t->proc);
    if(s){fail("Start identification tone",s);if(t->proc)AudioDeviceDestroyIOProcID(device,t->proc);free(t);return NULL;}
    return t;
}
void sp_tone_stop(SPTone *t){if(t){AudioDeviceStop(t->device,t->proc);AudioDeviceDestroyIOProcID(t->device,t->proc);free(t);}}
