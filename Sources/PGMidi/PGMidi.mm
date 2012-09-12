//
//  PGMidi.m
//  PGMidi
//
//  Created by Pete Goodliffe on 10/12/10
//  VirtualMIDI modifications by Michael Tyson, A Tasty Pixel
//  STL Queue modifications and ARC compatibility for VirtualMIDI by George McMullen, Quixonic
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import "PGMidi.h"
#import <mach/mach_time.h>

#import "PGArc.h"

// For some reason, this is nut pulled in by the umbrella header
#import <CoreMIDI/MIDINetworkSession.h>

/// A helper that NSLogs an error message if "c" is an error code
#define NSLogError(c,str) do{if (c) NSLog(@"Error (%@): %ld:%@", str, (long)c,[NSError errorWithDomain:NSMachErrorDomain code:c userInfo:nil]);}while(false)

//==============================================================================
// ARC


//==============================================================================

static void PGMIDINotifyProc(const MIDINotification *message, void *refCon);
static void PGMIDIReadProc(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon);
static void PGMIDIVirtualDestinationReadProc(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon);

@interface PGMidi ()
- (void) scanExistingDevices;
- (MIDIPortRef) outputPort;
@end

//==============================================================================

static
NSString *NameOfEndpoint(MIDIEndpointRef ref)
{
    NSString *string = nil;

    MIDIEntityRef entity = 0;
    MIDIEndpointGetEntity(ref, &entity);

    CFPropertyListRef properties = nil;
    OSStatus s = MIDIObjectGetProperties(entity, &properties, true);
    if (s)
    {
        CFStringRef str;
        str = NULL;
        MIDIObjectGetStringProperty(ref, kMIDIPropertyName, &str);

        if (str != NULL)
        {
            string = [NSString stringWithString:arc_cast<NSString>(str)];
            CFRelease(str);
        }
        else
        {
            string = @"Unknown name";
        }
    }
    else
    {
        //NSLog(@"Properties = %@", properties);
        NSDictionary *dictionary = arc_cast<NSDictionary>(properties);
        string = [NSString stringWithFormat:@"%@", [dictionary valueForKey:@"name"]];
        CFRelease(properties);
    }

    return string;
}

static
BOOL IsNetworkSession(MIDIEndpointRef ref)
{
    MIDIEntityRef entity = 0;
    MIDIEndpointGetEntity(ref, &entity);

    BOOL hasMidiRtpKey = NO;
    CFPropertyListRef properties = nil;
    OSStatus s = MIDIObjectGetProperties(entity, &properties, true);
    if (!s)
    {
        NSDictionary *dictionary = arc_cast<NSDictionary>(properties);
        hasMidiRtpKey = [dictionary valueForKey:@"apple.midirtp.session"] != nil;
        CFRelease(properties);
    }

    return hasMidiRtpKey;
}

//==============================================================================

@implementation PGMidiConnection

@synthesize midi;
@synthesize endpoint;
@synthesize name;
@synthesize isNetworkSession;

- (id) initWithMidi:(PGMidi*)m endpoint:(MIDIEndpointRef)e
{
    if ((self = [super init]))
    {
        midi                = m;
        endpoint            = e;
#if ! PGMIDI_ARC
        name                = [NameOfEndpoint(e) retain];
#else
        name                = NameOfEndpoint(e);
#endif
        isNetworkSession    = IsNetworkSession(e);
    }
    return self;
}

@end

//==============================================================================

@implementation PGMidiSource

@synthesize delegate;

- (id) initWithMidi:(PGMidi*)m endpoint:(MIDIEndpointRef)e
{
    if ((self = [super initWithMidi:m endpoint:e]))
    {
    }
    return self;
}

// NOTE: Called on a separate high-priority thread, not the main runloop
- (void) midiRead:(const MIDIPacketList *)pktlist
{
    // This has been modified to use a mutex and queue. See below why this should improve performance
    // http://www.cocoabuilder.com/archive/cocoa/141913-thread-messaging-cocoa-thread.html

    const MIDIPacket *packet = &pktlist->packet[0];
    for (int i = 0; i < pktlist->numPackets; ++i)
    {
        pthread_mutex_lock(&midi_incoming_mutex); // Lock the mutex only when writing to the queue
        midi_incoming_queue.push(*packet);
        pthread_mutex_unlock(&midi_incoming_mutex);
        packet = MIDIPacketNext(packet);
    }
 
    [delegate midiReceivedFromSource:self];
}

static
void PGMIDIReadProc(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon)
{
    PGMidiSource *self = arc_cast<PGMidiSource>(srcConnRefCon); // This seems to leak in ARC mode
    [self midiRead:pktlist];
}

static
void PGMIDIVirtualDestinationReadProc(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon)
{
    PGMidi *midi = arc_cast<PGMidi>(readProcRefCon);
    PGMidiSource *self = midi.virtualDestinationSource;
    [self midiRead:pktlist];
}

@end

//==============================================================================

@implementation PGMidiDestination

- (id) initWithMidi:(PGMidi*)m endpoint:(MIDIEndpointRef)e
{
    if ((self = [super initWithMidi:m endpoint:e]))
    {
        midi     = m;
        endpoint = e;
    }
    return self;
}

- (void) sendBytes:(const UInt8*)bytes size:(UInt32)size
{
#ifdef DEBUG
    NSLog(@"%s(%u bytes to core MIDI)", __func__, unsigned(size)); // Only log in debug mode
#endif
    assert(size < 65536);
    Byte packetBuffer[size+100];
    MIDIPacketList *packetList = (MIDIPacketList*)packetBuffer;
    MIDIPacket     *packet     = MIDIPacketListInit(packetList);
    packet = MIDIPacketListAdd(packetList, sizeof(packetBuffer), packet, 0, size, bytes);

    [self sendPacketList:packetList];
}

- (void) sendPacketList:(const MIDIPacketList *)packetList
{
    // Send it
    OSStatus s = MIDISend(midi.outputPort, endpoint, packetList);
    NSLogError(s, @"Sending MIDI");
}

@end

//==============================================================================

@interface PGMidiVirtualSourceDestination : PGMidiDestination
@end

@implementation PGMidiVirtualSourceDestination

- (void) sendBytes:(const UInt8*)bytes size:(UInt32)size
{
#ifdef DEBUG
    NSLog(@"%s(%u bytes to core MIDI)", __func__, unsigned(size)); // Only log in debug mode
#endif
    assert(size < 65536);
    Byte packetBuffer[size+100];
    MIDIPacketList *packetList = (MIDIPacketList*)packetBuffer;
    MIDIPacket     *packet     = MIDIPacketListInit(packetList);
    // According to: http://developer.apple.com/library/ios/documentation/CoreMidi/Reference/MIDIServices_Reference/Reference/reference.html#//apple_ref/c/func/MIDIReceived
    // The MIDIPacket needs to have a time stamp if it's being send (received) to a virtual port
    packet = MIDIPacketListAdd(packetList, sizeof(packetBuffer), packet, mach_absolute_time(), size, bytes);

    [self sendPacketList:packetList];
}

- (void) sendPacketList:(const MIDIPacketList *)packetList
{
    // Send it
    OSStatus s = MIDIReceived(endpoint, packetList);
    NSLogError(s, @"Sending MIDI");
}

@end

//==============================================================================

@implementation PGMidi

@synthesize delegate;
@synthesize sources,destinations,virtualSourceDestination,virtualDestinationSource,virtualEndpointName;
@dynamic networkEnabled, virtualSourceEnabled, virtualDestinationEnabled;

- (id) init
{
    if ((self = [super init]))
    {
        sources      = [NSMutableArray new];
        destinations = [NSMutableArray new];

        OSStatus s = MIDIClientCreate((CFStringRef)PGMIDI_CLIENTNAME, PGMIDINotifyProc, arc_cast<void>(self), &client);
        NSLogError(s, @"Create MIDI client");

        s = MIDIOutputPortCreate(client, (CFStringRef)PGMIDI_OUTPUTPORT, &outputPort);
        NSLogError(s, @"Create output MIDI port");

        s = MIDIInputPortCreate(client, (CFStringRef)PGMIDI_INPUTPORT, PGMIDIReadProc, arc_cast<void>(self), &inputPort);
        NSLogError(s, @"Create input MIDI port");

        [self scanExistingDevices];
    }

    return self;
}

- (void) dealloc
{
    if (outputPort)
    {
        OSStatus s = MIDIPortDispose(outputPort);
        NSLogError(s, @"Dispose MIDI port");
    }

    if (inputPort)
    {
        OSStatus s = MIDIPortDispose(inputPort);
        NSLogError(s, @"Dispose MIDI port");
    }

    if (client)
    {
        OSStatus s = MIDIClientDispose(client);
        NSLogError(s, @"Dispose MIDI client");
    }

    self.virtualEndpointName = nil;
    self.virtualSourceEnabled = NO;
    self.virtualDestinationEnabled = NO;

#if ! PGMIDI_ARC
    [sources release];
    [destinations release];
    [super dealloc];
#endif
}

- (NSUInteger) numberOfConnections
{
    return sources.count + destinations.count;
}

- (MIDIPortRef) outputPort
{
    return outputPort;
}

-(BOOL)networkEnabled
{
    return [MIDINetworkSession defaultSession].enabled;
}

- (void) enableNetwork:(BOOL)enabled
{
    MIDINetworkSession* session = [MIDINetworkSession defaultSession];
    session.enabled = YES;
    session.connectionPolicy = MIDINetworkConnectionPolicy_Anyone;
}

-(BOOL)virtualSourceEnabled
{
    return virtualSourceDestination != nil;
}

-(void)setVirtualSourceEnabled:(BOOL)virtualSourceEnabled {
    if ( virtualSourceEnabled == self.virtualSourceEnabled ) return;

    if ( virtualSourceEnabled ) {
        NSString *name = virtualEndpointName ? virtualEndpointName : [[[NSBundle mainBundle] infoDictionary] valueForKey:(NSString*)kCFBundleNameKey];
        OSStatus s = MIDISourceCreate(client, arc_refcast<CFStringRef>(name), &virtualSourceEndpoint);
        NSLogError(s, @"Create MIDI virtual source");
        if ( s != noErr ) return;

        virtualSourceDestination = [[PGMidiVirtualSourceDestination alloc] initWithMidi:self endpoint:virtualSourceEndpoint];

        [delegate midi:self destinationAdded:virtualSourceDestination];
    } else {
        [delegate midi:self destinationRemoved:virtualSourceDestination];

#if ! PGMIDI_ARC
        [virtualSourceDestination release]; virtualSourceDestination = nil;
#endif
        OSStatus s = MIDIEndpointDispose(virtualSourceEndpoint);
        NSLogError(s, @"Dispose MIDI virtual source");
        virtualSourceEndpoint = NULL;
    }
}

-(BOOL)virtualDestinationEnabled
{
    return virtualDestinationSource != nil;
}

-(void)setVirtualDestinationEnabled:(BOOL)virtualDestinationEnabled {
    if ( virtualDestinationEnabled == self.virtualDestinationEnabled ) return;

    if ( virtualDestinationEnabled ) {
        NSString *name = virtualEndpointName ? virtualEndpointName : [[[NSBundle mainBundle] infoDictionary] valueForKey:(NSString*)kCFBundleNameKey];
        OSStatus s = MIDIDestinationCreate(client, arc_refcast<CFStringRef>(name), PGMIDIVirtualDestinationReadProc, arc_cast<void>(self), &virtualDestinationEndpoint);
        NSLogError(s, @"Create MIDI virtual destination");
        if ( s != noErr ) return;

        // Attempt to use saved unique ID
        SInt32 uniqueID = [[NSUserDefaults standardUserDefaults] integerForKey:@"PGMIDI Saved Virtual Destination ID"];
        if ( uniqueID )
        {
            s = MIDIObjectSetIntegerProperty(virtualDestinationEndpoint, kMIDIPropertyUniqueID, uniqueID);
            if ( s == kMIDIIDNotUnique )
            {
                uniqueID = 0;
            }
        }
        // Save the ID
        if ( !uniqueID ) {
            OSStatus s = MIDIObjectGetIntegerProperty(virtualDestinationEndpoint, kMIDIPropertyUniqueID, &uniqueID);
            NSLogError(s, @"Get MIDI virtual destination ID");
            if ( s == noErr ) {
                [[NSUserDefaults standardUserDefaults] setInteger:uniqueID forKey:@"PGMIDI Saved Virtual Destination ID"];
            }
        }

        virtualDestinationSource = [[PGMidiSource alloc] initWithMidi:self endpoint:virtualDestinationEndpoint];

        [delegate midi:self sourceAdded:virtualDestinationSource];
    } else {
        [delegate midi:self sourceRemoved:virtualDestinationSource];

#if ! PGMIDI_ARC
        [virtualDestinationSource release]; virtualDestinationSource = nil;
#endif
        OSStatus s = MIDIEndpointDispose(virtualDestinationEndpoint);
        NSLogError(s, @"Dispose MIDI virtual destination");
        virtualDestinationEnabled = NO;
    }
}

//==============================================================================
#pragma mark Connect/disconnect

- (PGMidiSource*) getSource:(MIDIEndpointRef)source
{
    for (PGMidiSource *s in sources)
    {
        if (s.endpoint == source) return s;
    }
    return nil;
}

- (PGMidiDestination*) getDestination:(MIDIEndpointRef)destination
{
    for (PGMidiDestination *d in destinations)
    {
        if (d.endpoint == destination) return d;
    }
    return nil;
}

- (void) connectSource:(MIDIEndpointRef)endpoint
{
    PGMidiSource *source = [[PGMidiSource alloc] initWithMidi:self endpoint:endpoint];
    [sources addObject:source];
    [delegate midi:self sourceAdded:source];

    OSStatus s = MIDIPortConnectSource(inputPort, endpoint, arc_cast<void>(source));
    NSLogError(s, @"Connecting to MIDI source");
}

- (void) disconnectSource:(MIDIEndpointRef)endpoint
{
    PGMidiSource *source = [self getSource:endpoint];

    if (source)
    {
        OSStatus s = MIDIPortDisconnectSource(inputPort, endpoint);
        NSLogError(s, @"Disconnecting from MIDI source");

        [delegate midi:self sourceRemoved:source];

        [sources removeObject:source];
#if ! PGMIDI_ARC
        [source release];
#endif
    }
}

- (void) connectDestination:(MIDIEndpointRef)endpoint
{
    //[delegate midiInput:self event:@"Added a destination"];
    PGMidiDestination *destination = [[PGMidiDestination alloc] initWithMidi:self endpoint:endpoint];
    [destinations addObject:destination];
    [delegate midi:self destinationAdded:destination];
}

- (void) disconnectDestination:(MIDIEndpointRef)endpoint
{
    //[delegate midiInput:self event:@"Removed a device"];

    PGMidiDestination *destination = [self getDestination:endpoint];

    if (destination)
    {
        [delegate midi:self destinationRemoved:destination];
        [destinations removeObject:destination];
#if ! PGMIDI_ARC
        [destination release];
#endif
    }
}

- (void) scanExistingDevices
{
    const ItemCount numberOfDestinations = MIDIGetNumberOfDestinations();
    const ItemCount numberOfSources      = MIDIGetNumberOfSources();

    for (ItemCount index = 0; index < numberOfDestinations; ++index)
    {
        MIDIEndpointRef endpoint = MIDIGetDestination(index);
        if ( endpoint == virtualSourceEndpoint ) continue;
        [self connectDestination:endpoint];
    }
    for (ItemCount index = 0; index < numberOfSources; ++index)
    {
        MIDIEndpointRef endpoint = MIDIGetSource(index);
        if ( endpoint == virtualDestinationEndpoint ) continue;
        [self connectSource:endpoint];
    }
}

//==============================================================================
#pragma mark Notifications

- (void) midiNotifyAdd:(const MIDIObjectAddRemoveNotification *)notification
{
    if ( notification->child == virtualDestinationEndpoint || notification->child == virtualSourceEndpoint ) return;
    
    if (notification->childType == kMIDIObjectType_Destination)
        [self connectDestination:(MIDIEndpointRef)notification->child];
    else if (notification->childType == kMIDIObjectType_Source)
        [self connectSource:(MIDIEndpointRef)notification->child];
}

- (void) midiNotifyRemove:(const MIDIObjectAddRemoveNotification *)notification
{
    if ( notification->child == virtualDestinationEndpoint || notification->child == virtualSourceEndpoint ) return;

    if (notification->childType == kMIDIObjectType_Destination)
        [self disconnectDestination:(MIDIEndpointRef)notification->child];
    else if (notification->childType == kMIDIObjectType_Source)
        [self disconnectSource:(MIDIEndpointRef)notification->child];
}

- (void) midiNotify:(const MIDINotification*)notification
{
    switch (notification->messageID)
    {
        case kMIDIMsgObjectAdded:
            [self midiNotifyAdd:(const MIDIObjectAddRemoveNotification *)notification];
            break;
        case kMIDIMsgObjectRemoved:
            [self midiNotifyRemove:(const MIDIObjectAddRemoveNotification *)notification];
            break;
        case kMIDIMsgSetupChanged:
        case kMIDIMsgPropertyChanged:
        case kMIDIMsgThruConnectionsChanged:
        case kMIDIMsgSerialPortOwnerChanged:
        case kMIDIMsgIOError:
            break;
    }
}

void PGMIDINotifyProc(const MIDINotification *message, void *refCon)
{
    PGMidi *self = arc_cast<PGMidi>(refCon);
    [self midiNotify:message];
}

//==============================================================================
#pragma mark MIDI Output

- (void) sendPacketList:(const MIDIPacketList *)packetList
{
    for (ItemCount index = 0; index < MIDIGetNumberOfDestinations(); ++index)
    {
        MIDIEndpointRef outputEndpoint = MIDIGetDestination(index);
        if (outputEndpoint)
        {
            // Send it
            OSStatus s = MIDISend(outputPort, outputEndpoint, packetList);
            NSLogError(s, @"Sending MIDI");
        }
    }
}

- (void) sendBytes:(const UInt8*)data size:(UInt32)size
{
#ifdef DEBUG
    NSLog(@"%s(%u bytes to core MIDI)", __func__, unsigned(size)); // Only log in debug mode
#endif
    assert(size < 65536);
    Byte packetBuffer[size+100];
    MIDIPacketList *packetList = (MIDIPacketList*)packetBuffer;
    MIDIPacket     *packet     = MIDIPacketListInit(packetList);

    packet = MIDIPacketListAdd(packetList, sizeof(packetBuffer), packet, 0, size, data);

    [self sendPacketList:packetList];
}

@end
