//
//  PGMidi.h
//  PGMidi
//

#import <UIKit/UIKit.h>
#import <CoreMIDI/CoreMIDI.h>

#import "PGArc.h"

// IMPORTANT: EVERY .m file needs to be changed to a .mm file in order to use C++ STL
#include <queue>

#ifndef PGMIDI_CLIENTNAME
#define PGMIDI_CLIENTNAME @"MidiMonitor MIDI Client"
#endif

#ifndef PGMIDI_OUTPUTPORT
#define PGMIDI_OUTPUTPORT @"MidiMonitor Output Port"
#endif

#ifndef PGMIDI_INPUTPORT
#define PGMIDI_INPUTPORT @"MidiMonitor Input Port"
#endif

@class PGMidi;
@class PGMidiSource;


/// Represents a source/destination for MIDI data
///
/// @see PGMidiSource
/// @see PGMidiDestination
@interface PGMidiConnection : NSObject
{
    PGMidi                  *midi;
    MIDIEndpointRef          endpoint;
    NSString                *name;
    BOOL                     isNetworkSession;
}
@property (nonatomic,readonly) PGMidi          *midi;
@property (nonatomic,readonly) MIDIEndpointRef  endpoint;
@property (nonatomic,readonly) NSString        *name;
@property (nonatomic,readonly) BOOL             isNetworkSession;
@end


/// Delegate protocol for PGMidiSource class.
/// Adopt this protocol in your object to receive MIDI events
///
/// IMPORTANT NOTE:
/// MIDI input is received from a high priority background thread
///
/// @see PGMidiSource
@protocol PGMidiSourceDelegate

// Raised on main run loop
/// NOTE: Raised on high-priority background thread.
///
/// To do anything UI-ish, you must forward the event to the main runloop
/// (e.g. use performSelectorOnMainThread:withObject:waitUntilDone:)
///
/// Be careful about autoreleasing objects here - there is no NSAutoReleasePool.
///
/// Handle the data like this:
///
///     // for some function HandlePacketData(Byte *data, UInt16 length)
///     const MIDIPacket *packet = &packetList->packet[0];
///     for (int i = 0; i < packetList->numPackets; ++i)
///     {
///         HandlePacketData(packet->data, packet->length);
///         packet = MIDIPacketNext(packet);
///     }
- (void) midiReceivedFromSource:(PGMidiSource*)midi;

@end

/// Represents a source of MIDI data identified by CoreMIDI
///
/// @see PGMidiSourceDelegate
@interface PGMidiSource : PGMidiConnection
{
    id<PGMidiSourceDelegate> delegate;
@public
    pthread_mutex_t midi_incoming_mutex;
    std::queue<MIDIPacket> midi_incoming_queue;
}
@property (nonatomic,PGMIDI_DELEGATE_PROPERTY) id<PGMidiSourceDelegate> delegate;
@end

//==============================================================================

/// Represents a destination for MIDI data identified by CoreMIDI
@interface PGMidiDestination : PGMidiConnection
{
}
- (void) sendBytes:(const UInt8*)bytes size:(UInt32)size;
- (void) sendPacketList:(const MIDIPacketList *)packetList;
@end

//==============================================================================

/// Delegate protocol for PGMidi class.
///
/// @see PGMidi
@protocol PGMidiDelegate
- (void) midi:(PGMidi*)midi sourceAdded:(PGMidiSource *)source;
- (void) midi:(PGMidi*)midi sourceRemoved:(PGMidiSource *)source;
- (void) midi:(PGMidi*)midi destinationAdded:(PGMidiDestination *)destination;
- (void) midi:(PGMidi*)midi destinationRemoved:(PGMidiDestination *)destination;
@end

/// Class for receiving MIDI input from any MIDI device.
///
/// If you intend your app to support iOS 3.x which does not have CoreMIDI
/// support, weak link to the CoreMIDI framework, and only create a
/// PGMidi object if you are running the right version of iOS.
///
/// @see PGMidiDelegate
@interface PGMidi : NSObject
{
    MIDIClientRef      client;
    MIDIPortRef        outputPort;
    MIDIPortRef        inputPort;
    NSString          *virtualEndpointName;
    MIDIEndpointRef    virtualSourceEndpoint;
    MIDIEndpointRef    virtualDestinationEndpoint;
    PGMidiSource      *virtualDestinationSource;
    PGMidiDestination *virtualSourceDestination;
    id<PGMidiDelegate> delegate;
    NSMutableArray    *sources, *destinations;
}

@property (nonatomic,PGMIDI_DELEGATE_PROPERTY) id<PGMidiDelegate> delegate;

@property (nonatomic,readonly) NSUInteger         numberOfConnections;
@property (nonatomic,readonly) NSMutableArray    *sources;
@property (nonatomic,readonly) NSMutableArray    *destinations;
@property (nonatomic,readonly) PGMidiSource      *virtualDestinationSource;
@property (nonatomic,readonly) PGMidiDestination *virtualSourceDestination;
@property (nonatomic,retain)   NSString          *virtualEndpointName;
@property (nonatomic,assign) BOOL networkEnabled;
@property (nonatomic,assign) BOOL virtualSourceEnabled;
@property (nonatomic,assign) BOOL virtualDestinationEnabled;

/// Enables or disables CoreMIDI network connections
- (void) enableNetwork:(BOOL)enabled;

/// Send a MIDI byte stream to every connected MIDI port
- (void) sendBytes:(const UInt8*)bytes size:(UInt32)size;
- (void) sendPacketList:(const MIDIPacketList *)packetList;

@end
