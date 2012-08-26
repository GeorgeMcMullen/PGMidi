//
//  MidiMonitorViewController.m
//  MidiMonitor
//
//  Created by Pete Goodliffe on 10/14/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import "MidiMonitorViewController.h"

#import "PGMidi.h"
#import "iOSVersionDetection.h"
#import <CoreMIDI/CoreMIDI.h>

UInt8 RandomNoteNumber() { return UInt8(rand() / (RAND_MAX / 127)); }

@interface MidiMonitorViewController () <PGMidiDelegate, PGMidiSourceDelegate>
- (void) updateCountLabel;
- (void) addString:(NSString*)string;
- (void) sendMidiDataInBackground;
@end

@implementation MidiMonitorViewController

#pragma mark PGMidiDelegate

@synthesize countLabel;
@synthesize midi;

@synthesize midiTableView;
@synthesize dataSource;

#pragma mark UIViewController

- (void) viewWillAppear:(BOOL)animated
{
    dataSource = [[NSMutableArray alloc] init];

    [self clearTextView];
    [self updateCountLabel];

    IF_IOS_HAS_COREMIDI
    (
         [self addString:@"This iOS Version supports CoreMIDI"];
    )
    else
    {
        [self addString:@"You are running iOS before 4.2. CoreMIDI is not supported."];
    }
    [midiTableView reloadData];
}

- (void) dealloc
{
    self.midi = nil;
#if ! PGMIDI_ARC
    [midiTableView release];
    [dataSource release];
    [countLabel release];
    
    [super dealloc];
#endif
}

#pragma mark IBActions

- (IBAction) clearTextView
{
    [dataSource removeAllObjects];
    [midiTableView reloadData];
}

const char *ToString(BOOL b) { return b ? "yes":"no"; }

NSString *ToString(PGMidiConnection *connection)
{
    return [NSString stringWithFormat:@"< PGMidiConnection: name=%@ isNetwork=%s >",
            connection.name, ToString(connection.isNetworkSession)];
}
- (IBAction) listAllInterfaces
{
    IF_IOS_HAS_COREMIDI
    ({
        [self addString:@"\n\nInterface list:"];
        for (PGMidiSource *source in midi.sources)
        {
            NSString *description = [NSString stringWithFormat:@"Source: %@", ToString(source)];
            [self addString:description];
        }
        [self addString:@""];
        for (PGMidiDestination *destination in midi.destinations)
        {
            NSString *description = [NSString stringWithFormat:@"Destination: %@", ToString(destination)];
            [self addString:description];
        }
    })
    [self refreshTable];
}

- (IBAction) sendMidiData
{
    [self performSelectorInBackground:@selector(sendMidiDataInBackground) withObject:nil];
}

#pragma mark Shenanigans

- (void) attachToAllExistingSources
{
    for (PGMidiSource *source in midi.sources)
    {
        source.delegate = self;
    }
}

- (void) setMidi:(PGMidi*)m
{
    midi.delegate = nil;
    midi = m;
    midi.delegate = self;

    [self attachToAllExistingSources];
}

- (void) addString:(NSString*)string
{
    [dataSource addObject:string];
}

- (void) updateCountLabel
{
    countLabel.text = [NSString stringWithFormat:@"sources=%u destinations=%u", midi.sources.count, midi.destinations.count];
}

- (void) midi:(PGMidi*)midi sourceAdded:(PGMidiSource *)source
{
    source.delegate = self;
    [self updateCountLabel];
    [self addString:[NSString stringWithFormat:@"Source added: %@", ToString(source)]];
    [self refreshTable];
}

- (void) midi:(PGMidi*)midi sourceRemoved:(PGMidiSource *)source
{
    [self updateCountLabel];
    [self addString:[NSString stringWithFormat:@"Source removed: %@", ToString(source)]];
    [self refreshTable];
}

- (void) midi:(PGMidi*)midi destinationAdded:(PGMidiDestination *)destination
{
    [self updateCountLabel];
    [self addString:[NSString stringWithFormat:@"Destintation added: %@", ToString(destination)]];
    [self refreshTable];
}

- (void) midi:(PGMidi*)midi destinationRemoved:(PGMidiDestination *)destination
{
    [self updateCountLabel];
    [self addString:[NSString stringWithFormat:@"Destintation removed: %@", ToString(destination)]];
    [self refreshTable];
}

NSString *StringFromPacket(const MIDIPacket *packet)
{
    // Note - this is not an example of MIDI parsing. I'm just dumping
    // some bytes for diagnostics.
    // See comments in PGMidiSourceDelegate for an example of how to
    // interpret the MIDIPacket structure.
    return [NSString stringWithFormat:@"  %u bytes: [%02x,%02x,%02x]",
            packet->length,
            (packet->length > 0) ? packet->data[0] : 0,
            (packet->length > 1) ? packet->data[1] : 0,
            (packet->length > 2) ? packet->data[2] : 0
           ];
}

- (void) midiReceivedFromSource:(PGMidiSource*)_midi
{
    // You can do various other processing here if needed, but look out for memory errors
    [self performSelectorOnMainThread:@selector(processMidiFromSource:) withObject:_midi waitUntilDone:NO];
}

- (void) processMidiFromSource:(PGMidiSource*)_midi
{
    if (!_midi->midi_incoming_queue.empty())
        [self addString:@"MIDI received:"];

    while (!_midi->midi_incoming_queue.empty())
    {
        MIDIPacket packet =  _midi->midi_incoming_queue.front();
        [self addString:StringFromPacket(&packet)];
        pthread_mutex_lock(&_midi->midi_incoming_mutex); // Lock the mutex only when writing to the queue
        _midi->midi_incoming_queue.pop();
        pthread_mutex_unlock(&_midi->midi_incoming_mutex);
    }
    [self refreshTable];
}

- (void) sendMidiDataInBackground
{
    for (int n = 0; n < 20; ++n)
    {
        const UInt8 note      = RandomNoteNumber();
        const UInt8 noteOn[]  = { 0x90, note, 127 };
        const UInt8 noteOff[] = { 0x80, note, 0   };

        [midi sendBytes:noteOn size:sizeof(noteOn)];
        [NSThread sleepForTimeInterval:0.1];
        [midi sendBytes:noteOff size:sizeof(noteOff)];
    }
}

#pragma mark - UITableViewDelegate methods
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return 30.0f;
}

#pragma mark - UITableViewDataSource methods
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MIDITableCell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"MIDITableCell"];
        [cell setBackgroundColor:[UIColor blackColor]];
        [cell.textLabel setTextColor:[UIColor whiteColor]];
    }
    [cell.textLabel setText:[dataSource objectAtIndex:(NSUInteger)indexPath.row]];

    return cell;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)[dataSource count];
}

- (void)refreshTable
{
    [midiTableView reloadData];
    NSIndexPath* pathToScrollTo = [NSIndexPath indexPathForRow: (NSInteger)([dataSource count]-1) inSection: 0];
    [midiTableView scrollToRowAtIndexPath: pathToScrollTo atScrollPosition: UITableViewScrollPositionTop animated: YES];
}
@end
