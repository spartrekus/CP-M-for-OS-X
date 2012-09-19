//
//  BDOS.m
//  CPM for OS X
//
//  Created by Thomas Harte on 12/09/2012.
//  Copyright (c) 2012 Thomas Harte. All rights reserved.
//

#import "BDOS.h"

#import "RAMModule.h"
#import "Processor.h"
#import "BIOS.h"
#import "FileControlBlock.h"


@implementation CPMBDOS
{
	CPMRAMModule *_memory;
	CPMProcessor *_processor;
	CPMBIOS *_bios;

	uint16_t _dmaAddress;

	NSMutableDictionary *_fileHandlesByControlBlock;
}

+ (id)BDOSWithContentsOfURL:(NSURL *)URL terminalView:(CPMTerminalView *)terminalView
{
	return [self BDOSWithData:[NSData dataWithContentsOfURL:URL] terminalView:terminalView];
}

+ (id)BDOSWithData:(NSData *)data terminalView:(CPMTerminalView *)terminalView;
{
	return [[[self alloc] initWithData:data terminalView:terminalView] autorelease];
}

- (id)initWithData:(NSData *)data terminalView:(CPMTerminalView *)terminalView
{
	self = [super init];

	if(self)
	{
		// load the nominated executable
		if(!data || !terminalView)
		{
			[self release];
			return nil;
		}

		// create memory, a CPU and a BIOS
		_memory = [[CPMRAMModule RAMModule] retain];
		_processor = [[CPMProcessor processorWithRAM:_memory] retain];
		_bios = [[CPMBIOS BIOSWithTerminalView:terminalView processor:_processor] retain];

		// copy the executable into memory, set the initial program counter
		[_memory setData:data atAddress:0x100];
		_processor.programCounter = 0x100;

		// configure the bios trapping to occur as late as it can while
		// still having room for a full BIOS jump table
		uint16_t biosAddress = 65536-99;
		_processor.biosAddress = biosAddress;

		// we'll be the delegate, in order to trap all that stuff
		_processor.delegate = self;

		// setup the standard BIOS call
		[_memory setValue:0xc3 atAddress:0];
		[_memory setValue:(biosAddress+3)&0xff atAddress:1];
		[_memory setValue:(biosAddress+3) >> 8 atAddress:2];

		// set the call to perform BDOS functions to go to where the
		// BIOS theoretically starts — this is where the cold start
		// routine would go on a real CP/M machine and we're trying
		// to use the absolute minimal amount of memory possible
		[_memory setValue:0xc3 atAddress:5];
		[_memory setValue:biosAddress&0xff atAddress:6];
		[_memory setValue:biosAddress >> 8 atAddress:7];

		// set the top of the stack to be the address 0000 so that programs
		// that use return to exit function appropriately; also give SP a
		// sensible corresponding value
		[_memory setValue:0x00 atAddress:biosAddress-1];
		[_memory setValue:0x00 atAddress:biosAddress-2];
		_processor.spRegister = biosAddress-2;

		// also set the default DMA address
		_dmaAddress = 0x80;

		// allocate a dictionary to keep track of our open files
		_fileHandlesByControlBlock = [[NSMutableDictionary alloc] init];
	}

	return self;
}

- (void)dealloc
{
	[_memory release], _memory = nil;
	[_processor release], _processor = nil;
	[_bios release], _bios = nil;
	[_fileHandlesByControlBlock release], _fileHandlesByControlBlock = nil;
	[_basePath release], _basePath = nil;

	[super dealloc];
}

- (void)runForTimeInterval:(NSTimeInterval)interval;
{
	[_processor runForTimeInterval:interval];
}

- (CPMProcessorShouldBlock)processor:(CPMProcessor *)processor isMakingBDOSCall:(uint8_t)call parameter:(uint16_t)parameter
{
//		case 10:	/* buffered console input */					break;

	CPMProcessorShouldBlock shouldBlock = NO;

	switch(call)
	{
		case 0:		shouldBlock = [self exitProgram];								break;
		case 2:		shouldBlock = [self writeConsoleOutput:parameter];				break;
		case 6:		shouldBlock = [self directConsoleIOWithParameter:parameter];	break;
		case 9:		shouldBlock = [self outputStringWithParameter:parameter];		break;
		case 11:	shouldBlock = [self getConsoleStatus];							break;
		case 12:	shouldBlock = [self liftHead];									break;
		case 13:	shouldBlock = [self resetAllDisks];								break;
		case 15:	shouldBlock = [self openFileWithParameter:parameter];			break;
		case 16:	shouldBlock = [self closeFileWithParameter:parameter];			break;
		case 20:	shouldBlock = [self readNextRecordWithParameter:parameter];		break;
		case 25:	shouldBlock = [self getCurrentDrive];							break;
		case 26:	shouldBlock = [self setDMAAddressWithParameter:parameter];		break;
		case 33:	shouldBlock = [self readRandomRecordWithParameter:parameter];	break;

		case 17:	// search for first
			NSLog(@"file search: TODO");
			processor.afRegister |= 0xff00;
		break;

		case 14:	// select disk
			processor.afRegister = (processor.afRegister&0x00ff);
		break;

		default:
			NSLog(@"!!UNIMPLEMENTED!! BDOS call %d with parameter %04x", call, parameter);
		break;
	}

	// "For reasons of compatibility, register A = L and register B = H upon return in all cases."
	processor.hlRegister = (processor.afRegister >> 8) | (processor.bcRegister & 0xff00);

	return shouldBlock;
}

- (CPMProcessorShouldBlock)processor:(CPMProcessor *)processor isMakingBIOSCall:(uint8_t)call
{
	// we've cheekily set up BIOS call 0 to be our BDOS entry point,
	// so we'll redirect BIOS call 0 manually
	if(!call)
	{
		return [self processor:processor isMakingBDOSCall:processor.bcRegister&0xff parameter:processor.deRegister];
	}

	return [_bios makeCall:call];
}

- (void)processorDidHalt:(CPMProcessor *)processor
{
	NSLog(@"!!Processor did halt!!");
}


- (BOOL)writeConsoleOutput:(uint16_t)character
{
	[_bios writeConsoleOutput:character&0xff];
	return NO;
}

- (BOOL)exitProgram
{
	NSLog(@"Program did exit");
	return YES;
}

- (BOOL)liftHead
{
	_processor.hlRegister = 0;
	return NO;
}

- (BOOL)resetAllDisks
{
	_dmaAddress = 0x80;
	return NO;
}

- (BOOL)getCurrentDrive
{
	// return current drive in a; a = 0, b = 1, etc
	NSLog(@"Returned current drive as 0");
	_processor.afRegister &= 0xff;

	return NO;
}

- (CPMFileControlBlock *)fileControlBlockWithParameter:(uint16_t)parameter
{
	return [CPMFileControlBlock fileControlBlockWithAddress:parameter inMemory:_memory];
}

- (BOOL)openFileWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];

	NSError *error = nil;

	NSString *fullPath = [NSString stringWithFormat:@"%@.%@", fileControlBlock.fileName, fileControlBlock.fileType];
	if(self.basePath)
	{
		fullPath = [self.basePath stringByAppendingPathComponent:fullPath];
	}
	NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:fullPath];

	if(handle && !error)
	{
		NSLog(@"Opened %@ for record %04x", fileControlBlock, parameter);

		_processor.afRegister &= 0xff;
		[_fileHandlesByControlBlock setObject:handle forKey:fileControlBlock];
	}
	else
	{
		NSLog(@"Failed to open %@", fileControlBlock);
		_processor.afRegister |= 0xff00;
	}

	return NO;
}

- (BOOL)closeFileWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];

	NSLog(@"Closing %@", fileControlBlock);
	[_fileHandlesByControlBlock removeObjectForKey:fileControlBlock];
	_processor.afRegister &= 0xff;

	return NO;
}

- (BOOL)setDMAAddressWithParameter:(uint16_t)parameter
{
	_dmaAddress = parameter;

	return NO;
}

- (BOOL)readNextRecordWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];
	NSFileHandle *fileHandle = [_fileHandlesByControlBlock objectForKey:fileControlBlock];

	[fileHandle seekToFileOffset:fileControlBlock.linearFileOffset];
	NSData *nextRecord = [fileHandle readDataOfLength:128];
	if([nextRecord length])
	{
		[_memory setData:nextRecord atAddress:_dmaAddress];

		// sequential reads update the FCB
		fileControlBlock.linearFileOffset += 128;

		// report success
		_processor.afRegister = (_processor.afRegister&0x00ff);
	}
	else
	{
		// set 0xff - end of file
		_processor.afRegister = 0xff00 | (_processor.afRegister&0x00ff);
	}

//	NSLog(@"did read sequential record for %@, offset %zd, DMA address %04x", fileControlBlock, fileControlBlock.linearFileOffset, _dmaAddress);

	return NO;
}

- (BOOL)readRandomRecordWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];
	NSFileHandle *fileHandle = [_fileHandlesByControlBlock objectForKey:fileControlBlock];
	
	[fileHandle seekToFileOffset:fileControlBlock.randomFileOffset];
	NSData *nextRecord = [fileHandle readDataOfLength:128];

	if([nextRecord length])
	{
		[_memory setData:nextRecord atAddress:_dmaAddress];

		// report success
		_processor.afRegister = (_processor.afRegister&0x00ff);
	}
	else
	{
		// set error 6 - record number out of range
		_processor.afRegister = 0x0600 | (_processor.afRegister&0x00ff);
	}

//	NSLog(@"did read random record for %@, offset %zd, DMA address %04x", fileControlBlock, fileControlBlock.randomFileOffset, _dmaAddress);

	return NO;
}

- (BOOL)directConsoleIOWithParameter:(uint16_t)parameter
{
	switch(parameter&0xff)
	{
		case 0xff:
			_processor.afRegister = (_processor.afRegister&0x00ff) | ([_bios dequeueCharacterIfAvailable] << 8);
		break;
		case 0xfe: return [self getConsoleStatus];
		default:
			[_bios writeConsoleOutput:parameter&0xff];
		break;
	}

	return NO;
}

- (BOOL)getConsoleStatus
{
	_processor.afRegister = (_processor.afRegister&0x00ff) | ([_bios consoleStatus] << 8);
	return NO;
}

- (BOOL)outputStringWithParameter:(uint16_t)parameter
{
	while(1)
	{
		uint8_t nextCharacter = [_memory valueAtAddress:parameter];
		if(nextCharacter == '$') break;
		[_bios writeConsoleOutput:nextCharacter];
		parameter++;
	}
	return NO;
}

@end
