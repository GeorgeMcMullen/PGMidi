//
//  MidiMonitorViewController.h
//  MidiMonitor
//
//  Created by Pete Goodliffe on 10/14/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import <UIKit/UIKit.h>

@class PGMidi;

@interface MidiMonitorViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
{
    UILabel    *countLabel;

    UITableView *midiTableView;
    NSMutableArray *dataSource;

    PGMidi *midi;
}

#if ! __has_feature(objc_arc)

@property (nonatomic,retain) IBOutlet UILabel    *countLabel;
@property (nonatomic,retain) IBOutlet UITableView *midiTableView;
@property (nonatomic,retain) NSMutableArray *dataSource;

@property (nonatomic,assign) PGMidi *midi;

#else

@property (nonatomic,strong) IBOutlet UILabel    *countLabel;
@property (nonatomic,strong) IBOutlet UITableView *midiTableView;
@property (nonatomic,strong) NSMutableArray *dataSource;

@property (nonatomic,strong) PGMidi *midi;

#endif

- (IBAction) clearTextView;
- (IBAction) listAllInterfaces;
- (IBAction) sendMidiData;

@end

