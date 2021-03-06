//
//  Loader.m
//  XBee Loader
//
//	THe loader moves compiled binary images to the Propeller via an XBee board.
//
//  Created by Mike Westerfield on 7/15/14 at the Byte Works, Inc.
//  Copyright (c) 2014 Parallax. All rights reserved.
//

#import "Loader.h"

#include <pthread.h>

#include "Common.h"
#include "XBeeCommon.h"
#import "UDPDataBuffer.h"

#define DEBUG_ME (0)
#define PACKET_DUMP (0)

#define CLOCK_MODE_INDEX (4)				/* The default clock mode index. Unused for now; may be set later by a user control. */
#define CLOCK_SPEED (80000000)				/* The clock speed. */
#define DEFAULT_MAX_DATA_SIZE (1392)		/* The default maximum size for a single UDP packet. */
#define DYNAMIC_WAIT_FACTOR (2.0)           /* Multiply factor for dynamic waits; x times maximum round-trip time */
#define FINAL_BAUD (115200)					/* Final XBee-to-Propeller baud rate. */
#define HEADER_SIZE (4)						/* The size for the header in a UDP packet. */
#define INITIL_BAUD (115200)             	/* Initial XBee-to-Propeller baud rate */
#define MAX_DATA_SIZE (1392)				/* Maximum number of bytes in one UDP packet. */
#define MAX_RX_SENSE_ERROR (23)				/* Maximum number of cycles by which the detection of a start bit could be off (as affected by the Loader code) */
#define MIN_SER_TIMEOUT (0.1)				/* The minimum allowed value for a serial timeout. */
#define SER_TIMEOUT (1.0)					/* Amount of time to wait before assuming a serial response will not arrive. */
#define SCL_LOW_TIME (0.0000013)			/* Serial Clock Low Time (in seconds). */
#define SCL_HIGH_TIME (0.0000006)			/* Serial Clock High Time (in seconds). */
#define SSSH_TIME (0.0000006)				/* Start/Stop Setup/Hold Time (in seconds). */
//#define SSSH_TIME (0.0000012)				/* Start/Stop Setup/Hold Time (in seconds) for beta boards with a 100KΩ resistor. */
#define UDP_TIMEOUT (2.0)					/* Seconds before a UDP timeout. */

static Loader *this;						// This singleton instance of this class.
static BOOL mutexInitialized = FALSE;		// Has the mutex been initialized?

#define INIT_CALL_FRAME_SIZE (8)			/* Size of the initCallFrame array. */
static UInt8 initCallFrame[INIT_CALL_FRAME_SIZE] = {0xFF, 0xFF, 0xF9, 0xFF, 0xFF, 0xFF, 0xF9, 0xFF};


// Raw loader image.  This is a memory image of a Propeller Application written in PASM that fits into our initial
// download packet.  Once started, it assists with the remainder of the download (at a faster speed and with more
// relaxed interstitial timing conducive of Internet Protocol delivery. This memory image isn't used as-is; before
// download, it is first adjusted to contain special values assigned by this host (communication timing and
// synchronization values) and then is translated into an optimized Propeller Download Stream understandable by the
// Propeller ROM-based boot loader.
#define RAW_LOADER_IMAGE_SIZE (392)			/* Size of the rawLoaderImage array. */
static UInt8 rawLoaderImage[RAW_LOADER_IMAGE_SIZE] = {
    0x00,0xB4,0xC4,0x04,0x6F,0x2B,0x10,0x00,0x88,0x01,0x90,0x01,0x80,0x01,0x94,0x01,
    0x78,0x01,0x02,0x00,0x70,0x01,0x00,0x00,0x4D,0xE8,0xBF,0xA0,0x4D,0xEC,0xBF,0xA0,
    0x51,0xB8,0xBC,0xA1,0x01,0xB8,0xFC,0x28,0xF1,0xB9,0xBC,0x80,0xA0,0xB6,0xCC,0xA0,
    0x51,0xB8,0xBC,0xF8,0xF2,0x99,0x3C,0x61,0x05,0xB6,0xFC,0xE4,0x59,0x24,0xFC,0x54,
    0x62,0xB4,0xBC,0xA0,0x02,0xBC,0xFC,0xA0,0x51,0xB8,0xBC,0xA0,0xF1,0xB9,0xBC,0x80,
    0x04,0xBE,0xFC,0xA0,0x08,0xC0,0xFC,0xA0,0x51,0xB8,0xBC,0xF8,0x4D,0xE8,0xBF,0x64,
    0x01,0xB2,0xFC,0x21,0x51,0xB8,0xBC,0xF8,0x4D,0xE8,0xBF,0x70,0x12,0xC0,0xFC,0xE4,
    0x51,0xB8,0xBC,0xF8,0x4D,0xE8,0xBF,0x68,0x0F,0xBE,0xFC,0xE4,0x48,0x24,0xBC,0x80,
    0x0E,0xBC,0xFC,0xE4,0x52,0xA2,0xBC,0xA0,0x54,0x44,0xFC,0x50,0x61,0xB4,0xFC,0xA0,
    0x5A,0x5E,0xBC,0x54,0x5A,0x60,0xBC,0x54,0x5A,0x62,0xBC,0x54,0x04,0xBE,0xFC,0xA0,
    0x54,0xB6,0xBC,0xA0,0x53,0xB8,0xBC,0xA1,0x00,0xBA,0xFC,0xA0,0x80,0xBA,0xFC,0x72,
    0xF2,0x99,0x3C,0x61,0x25,0xB6,0xF8,0xE4,0x36,0x00,0x78,0x5C,0xF1,0xB9,0xBC,0x80,
    0x51,0xB8,0xBC,0xF8,0xF2,0x99,0x3C,0x61,0x00,0xBB,0xFC,0x70,0x01,0xBA,0xFC,0x29,
    0x2A,0x00,0x4C,0x5C,0xFF,0xC2,0xFC,0x64,0x5D,0xC2,0xBC,0x68,0x08,0xC2,0xFC,0x20,
    0x55,0x44,0xFC,0x50,0x22,0xBE,0xFC,0xE4,0x01,0xB4,0xFC,0x80,0x1E,0x00,0x7C,0x5C,
    0x22,0xB6,0xBC,0xA0,0xFF,0xB7,0xFC,0x60,0x54,0xB6,0x7C,0x86,0x00,0x8E,0x68,0x0C,
    0x59,0xC2,0x3C,0xC2,0x09,0x00,0x54,0x5C,0x01,0xB2,0xFC,0xC1,0x63,0x00,0x70,0x5C,
    0x63,0xB4,0xFC,0x84,0x45,0xC6,0x3C,0x08,0x04,0x8A,0xFC,0x80,0x48,0x7E,0xBC,0x80,
    0x3F,0xB4,0xFC,0xE4,0x63,0x7E,0xFC,0x54,0x09,0x00,0x7C,0x5C,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x80,0x00,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x80,0x00,0x00,
    0xFF,0xFF,0xF9,0xFF,0x10,0xC0,0x07,0x00,0x00,0x00,0x00,0x80,0x00,0x00,0x00,0x40,
    0x00,0x00,0x00,0x20,0x00,0x00,0x00,0x10,0x6F,0x00,0x00,0x00,0xB6,0x02,0x00,0x00,
    0x56,0x00,0x00,0x00,0x82,0x00,0x00,0x00,0x55,0x73,0xCB,0x00,0x18,0x51,0x00,0x00,
    0x30,0x00,0x00,0x00,0x30,0x00,0x00,0x00,0x68,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x35,0xC7,0x08,0x35,0x2C,0x32,0x00,0x00};

// Offset (in bytes) from end of Raw Loader Image (above) to the start of host-initialized values exist within it.  
// Host-Initialized values are constants in the source (Propeller Assembly code) that are intended to be replaced 
// by the host (the computer running 'this' code) before packetization and transmission of the image to the Propeller.
// Host-Initialized Values are Initial Bit Time, Final Bit Time, 1.5x Bit Time, Failsafe timeout, End of Packet 
// Timeout, Start/Stop Time, SCL High Time, SCL Low Time, and ExpectedID.  In addition to replacing these values, the
// host needs to update the image checksum at word 5.
//
// NOTE: DAT block data is always placed before the first Spin method.
							   // Value Bytes  Spin Bytes
#define RAW_LOADER_INIT_OFFSET - (   10*4   ) - (    8   )

// Propeller Download Stream Translator array.  Index into this array using the "Binary Value" (usually 5 bits) to translate,
// the incoming bit size (again, usually 5), and the desired data element to retrieve (dtTx = translation, dtBits = bit count
// actually translated.

// Binary    Incoming    Translation
// Value,    Bit Size,   or Bit Count
static UInt8 PDSTx[32][5][2] =

//  ***  1-BIT  ***        ***  2-BIT  ***        ***  3-BIT  ***        ***  4-BIT  ***        ***  5-BIT  ***
{ { /*%00000*/ {0xFE, 1},  /*%00000*/ {0xF2, 2},  /*%00000*/ {0x92, 3},  /*%00000*/ {0x92, 3},  /*%00000*/ {0x92, 3} },
  { /*%00001*/ {0xFF, 1},  /*%00001*/ {0xF9, 2},  /*%00001*/ {0xC9, 3},  /*%00001*/ {0xC9, 3},  /*%00001*/ {0xC9, 3} },
  {            {0,    0},  /*%00010*/ {0xFA, 2},  /*%00010*/ {0xCA, 3},  /*%00010*/ {0xCA, 3},  /*%00010*/ {0xCA, 3} },
  {            {0,    0},  /*%00011*/ {0xFD, 2},  /*%00011*/ {0xE5, 3},  /*%00011*/ {0x25, 4},  /*%00011*/ {0x25, 4} },
  {            {0,    0},             {0,    0},  /*%00100*/ {0xD2, 3},  /*%00100*/ {0xD2, 3},  /*%00100*/ {0xD2, 3} },
  {            {0,    0},             {0,    0},  /*%00101*/ {0xE9, 3},  /*%00101*/ {0x29, 4},  /*%00101*/ {0x29, 4} },
  {            {0,    0},             {0,    0},  /*%00110*/ {0xEA, 3},  /*%00110*/ {0x2A, 4},  /*%00110*/ {0x2A, 4} },
  {            {0,    0},             {0,    0},  /*%00111*/ {0xFA, 3},  /*%00111*/ {0x95, 4},  /*%00111*/ {0x95, 4} },
  {            {0,    0},             {0,    0},             {0,    0},  /*%01000*/ {0x92, 3},  /*%01000*/ {0x92, 3} },
  {            {0,    0},             {0,    0},             {0,    0},  /*%01001*/ {0x49, 4},  /*%01001*/ {0x49, 4} },
  {            {0,    0},             {0,    0},             {0,    0},  /*%01010*/ {0x4A, 4},  /*%01010*/ {0x4A, 4} },
  {            {0,    0},             {0,    0},             {0,    0},  /*%01011*/ {0xA5, 4},  /*%01011*/ {0xA5, 4} },
  {            {0,    0},             {0,    0},             {0,    0},  /*%01100*/ {0x52, 4},  /*%01100*/ {0x52, 4} },
  {            {0,    0},             {0,    0},             {0,    0},  /*%01101*/ {0xA9, 4},  /*%01101*/ {0xA9, 4} },
  {            {0,    0},             {0,    0},             {0,    0},  /*%01110*/ {0xAA, 4},  /*%01110*/ {0xAA, 4} },
  {            {0,    0},             {0,    0},             {0,    0},  /*%01111*/ {0xD5, 4},  /*%01111*/ {0xD5, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%10000*/ {0x92, 3} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%10001*/ {0xC9, 3} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%10010*/ {0xCA, 3} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%10011*/ {0x25, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%10100*/ {0xD2, 3} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%10101*/ {0x29, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%10110*/ {0x2A, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%10111*/ {0x95, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%11000*/ {0x92, 3} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%11001*/ {0x49, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%11010*/ {0x4A, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%11011*/ {0xA5, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%11100*/ {0x52, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%11101*/ {0xA9, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%11110*/ {0xAA, 4} },
  {            {0,    0},             {0,    0},             {0,    0},             {0,    0},  /*%11111*/ {0x55, 5} }
 };
#define DT_TX (0)          /* Data type: Translation pattern; third index of PDSTx array. */
#define DT_BITS (1)        /* Data type: Bits translated; third index of PDSTx array. */


// After reset, the Propeller's exact clock rate is not known by either the host or the Propeller itself, so communication
// with the Propeller takes place based on a host-transmitted timing template that the Propeller uses to read the stream
// and generate the responses.  The host first transmits the 2-bit timing template, then transmits a 250-bit Tx handshake,
// followed by 250 timing templates (one for each Rx handshake bit expected) which the Propeller uses to properly transmit
// the Rx handshake sequence.  Finally, the host transmits another eight timing templates (one for each bit of the
// Propeller's version number expected) which the Propeller uses to properly transmit it's 8-bit hardware/firmware version
// number.
//
// After the Tx Handshake and Rx Handshake are properly exchanged, the host and Propeller are considered "connected," at
// which point the host can send a download command followed by image size and image data, or simply end the communication.
//
// PROPELLER HANDSHAKE SEQUENCE: The handshake (both Tx and Rx) are based on a Linear Feedback Shift Register (LFSR) tap
// sequence that repeats only after 255 iterations.  The generating LFSR can be created in Pascal code as the following function
// (assuming FLFSR is pre-defined Byte variable that is set to ord('P') prior to the first call of IterateLFSR).  This is
// the exact function that was used in previous versions of the Propeller Tool and Propellent software.
//
//		function IterateLFSR: Byte;
//		begin //Iterate LFSR, return previous bit 0
//		Result := FLFSR and 0x01;
//		FLFSR := FLFSR shl 1 and 0xFE or (FLFSR shr 7 xor FLFSR shr 5 xor FLFSR shr 4 xor FLFSR shr 1) and 1;
//		end;
//
// The handshake bit stream consists of the lowest bit value of each 8-bit result of the LFSR described above.  This LFSR
// has a domain of 255 combinations, but the host only transmits the first 250 bits of the pattern, afterwards, the Propeller
// generates and transmits the next 250-bits based on continuing with the same LFSR sequence.  In this way, the host-
// transmitted (host-generated) stream ends 5 bits before the LFSR starts repeating the initial sequence, and the host-
// received (Propeller generated) stream that follows begins with those remaining 5 bits and ends with the leading 245 bits
// of the host-transmitted stream.
//
// For speed and compression reasons, this handshake stream has been encoded as tightly as possible into the pattern
// described below.

// Loader executable snippets.
typedef enum {ltCore, ltVerifyRAM, ltProgramEEPROM, ltReadyToLaunch, ltLaunchNow} typeLoaderType;

// Loader VerifyRAM snippet; use with ltVerifyRAM.
#define VERIFY_RAM_LENGTH (68)
UInt8 verifyRAM[VERIFY_RAM_LENGTH] = {
    0x49,0xBC,0xBC,0xA0,0x45,0xBC,0xBC,0x84,0x02,0xBC,0xFC,0x2A,0x45,0x8C,0x14,0x08,
    0x04,0x8A,0xD4,0x80,0x66,0xBC,0xD4,0xE4,0x0A,0xBC,0xFC,0x04,0x04,0xBC,0xFC,0x84,
    0x5E,0x94,0x3C,0x08,0x04,0xBC,0xFC,0x84,0x5E,0x94,0x3C,0x08,0x01,0x8A,0xFC,0x84,
    0x45,0xBE,0xBC,0x00,0x5F,0x8C,0xBC,0x80,0x6E,0x8A,0x7C,0xE8,0x46,0xB2,0xBC,0xA4,
    0x09,0x00,0x7C,0x5C};

// Loader ProgramVerifyEEPROM snippet; use with ltProgramEEPROM.
#define VERIFY_EEPROM_LENGTH (316)
UInt8 verifyEEPROM[VERIFY_EEPROM_LENGTH]= {
    0x03,0x8C,0xFC,0x2C,0x4F,0xEC,0xBF,0x68,0x82,0x18,0xFD,0x5C,0x40,0xBE,0xFC,0xA0,
    0x45,0xBA,0xBC,0x00,0xA0,0x62,0xFD,0x5C,0x79,0x00,0x70,0x5C,0x01,0x8A,0xFC,0x80,
    0x67,0xBE,0xFC,0xE4,0x8F,0x3E,0xFD,0x5C,0x49,0x8A,0x3C,0x86,0x65,0x00,0x54,0x5C,
    0x00,0x8A,0xFC,0xA0,0x49,0xBE,0xBC,0xA0,0x7D,0x02,0xFD,0x5C,0xA3,0x62,0xFD,0x5C,
    0x45,0xC0,0xBC,0x00,0x5D,0xC0,0x3C,0x86,0x79,0x00,0x54,0x5C,0x01,0x8A,0xFC,0x80,
    0x72,0xBE,0xFC,0xE4,0x01,0x8C,0xFC,0x28,0x8F,0x3E,0xFD,0x5C,0x01,0x8C,0xFC,0x28,
    0x46,0xB2,0xBC,0xA4,0x09,0x00,0x7C,0x5C,0x82,0x18,0xFD,0x5C,0xA1,0xBA,0xFC,0xA0,
    0x8D,0x62,0xFD,0x5C,0x79,0x00,0x70,0x5C,0x00,0x00,0x7C,0x5C,0xFF,0xBD,0xFC,0xA0,
    0xA0,0xBA,0xFC,0xA0,0x8D,0x62,0xFD,0x5C,0x83,0xBC,0xF0,0xE4,0x45,0xBA,0x8C,0xA0,
    0x08,0xBA,0xCC,0x28,0xA0,0x62,0xCD,0x5C,0x45,0xBA,0x8C,0xA0,0xA0,0x62,0xCD,0x5C,
    0x79,0x00,0x70,0x5C,0x00,0x00,0x7C,0x5C,0x47,0x8E,0x3C,0x62,0x90,0x00,0x7C,0x5C,
    0x47,0x8E,0x3C,0x66,0x09,0xC0,0xFC,0xA0,0x58,0xB8,0xBC,0xA0,0xF1,0xB9,0xBC,0x80,
    0x4F,0xE8,0xBF,0x64,0x4E,0xEC,0xBF,0x78,0x56,0xB8,0xBC,0xF8,0x4F,0xE8,0xBF,0x68,
    0xF2,0x9D,0x3C,0x61,0x56,0xB8,0xBC,0xF8,0x4E,0xEC,0xBB,0x7C,0x00,0xB8,0xF8,0xF8,
    0xF2,0x9D,0x28,0x61,0x91,0xC0,0xCC,0xE4,0x79,0x00,0x44,0x5C,0x7B,0x00,0x48,0x5C,
    0x00,0x00,0x68,0x5C,0x01,0xBA,0xFC,0x2C,0x01,0xBA,0xFC,0x68,0xA4,0x00,0x7C,0x5C,
    0xFE,0xBB,0xFC,0xA0,0x09,0xC0,0xFC,0xA0,0x58,0xB8,0xBC,0xA0,0xF1,0xB9,0xBC,0x80,
    0x4F,0xE8,0xBF,0x64,0x00,0xBB,0x7C,0x62,0x01,0xBA,0xFC,0x34,0x4E,0xEC,0xBF,0x78,
    0x57,0xB8,0xBC,0xF8,0x4F,0xE8,0xBF,0x68,0xF2,0x9D,0x3C,0x61,0x58,0xB8,0xBC,0xF8,
    0xA7,0xC0,0xFC,0xE4,0xFF,0xBA,0xFC,0x60,0x00,0x00,0x7C,0x5C};

// Loader ReadyToLaunch snippet; use with ltReadyToLaunch.
#define READY_TO_LAUNCH_LENGTH (60)
UInt8 readyToLaunch[READY_TO_LAUNCH_LENGTH] = {
    0xB8,0x72,0xFC,0x58,0x66,0x72,0xFC,0x50,0x09,0x00,0x7C,0x5C,0x06,0xBE,0xFC,0x04,
    0x10,0xBE,0x7C,0x86,0x00,0x8E,0x54,0x0C,0x04,0xBE,0xFC,0x00,0x78,0xBE,0xFC,0x60,
    0x50,0xBE,0xBC,0x68,0x00,0xBE,0x7C,0x0C,0x40,0xAE,0xFC,0x2C,0x6E,0xAE,0xFC,0xE4,
    0x04,0xBE,0xFC,0x00,0x00,0xBE,0x7C,0x0C,0x02,0x96,0x7C,0x0C};

// Loader LaunchNow snippet; use with ltLaunchNow.
#define LAUNCH_NOW_LENGTH (4)
UInt8 launchNow[LAUNCH_NOW_LENGTH] = {
    0x66,0x00,0x7C,0x5C};

// The TxHandshake array consists of 209 bytes that are encoded to represent the required '1' and '0' timing 
// template bits, 250 bits representing the lowest bit values of 250 iterations of the Propeller LFSR (seeded 
// with ASCII 'P'), 250 more timing template bits to receive the Propeller's handshake response, and more to 
// receive the version.
#define TX_HANDSHAKE_LENGTH (209)
UInt8 txHandshake[TX_HANDSHAKE_LENGTH] = {
    // First timing template ('1' and '0') plus first two bits of handshake ('0' and '1').
    0x49,
    // Remaining 248 bits of handshake...
    0xAA,0x52,0xA5,0xAA,0x25,0xAA,0xD2,0xCA,0x52,0x25,0xD2,0xD2,0xD2,0xAA,0x49,0x92,
    0xC9,0x2A,0xA5,0x25,0x4A,0x49,0x49,0x2A,0x25,0x49,0xA5,0x4A,0xAA,0x2A,0xA9,0xCA,
    0xAA,0x55,0x52,0xAA,0xA9,0x29,0x92,0x92,0x29,0x25,0x2A,0xAA,0x92,0x92,0x55,0xCA,
    0x4A,0xCA,0xCA,0x92,0xCA,0x92,0x95,0x55,0xA9,0x92,0x2A,0xD2,0x52,0x92,0x52,0xCA,
    0xD2,0xCA,0x2A,0xFF,
    // 250 timing templates ('1' and '0') to receive 250-bit handshake from Propeller.
    // This is encoded as two pairs per byte; 125 bytes.
    0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,
    0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,
    0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,
    0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,
    0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,
    0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,
    0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,
    0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,0x29,
    // 8 timing templates ('1' and '0') to receive 8-bit Propeller version; two pairs 
    // per byte; 4 bytes.
    0x29,0x29,0x29,0x29,                                    
    // Download command (1; program RAM and run); 11 bytes.
    0x93,0x92,0x92,0x92,0x92,0x92,0x92,0x92,0x92,0x92,0xF2};

// The RxHandshake array consists of 125 bytes encoded to represent the expected 250-bit (125-byte @ 2 
// bits/byte) response of continuing-LFSR stream bits from the Propeller, prompted by the timing templates 
// following the TxHandshake stream.
#define RX_HANDSHAKE_LENGTH (125)
UInt8 rxHandshake[RX_HANDSHAKE_LENGTH] = {
    0xEE,0xCE,0xCE,0xCF,0xEF,0xCF,0xEE,0xEF,0xCF,0xCF,0xEF,0xEF,0xCF,0xCE,0xEF,0xCF,
    0xEE,0xEE,0xCE,0xEE,0xEF,0xCF,0xCE,0xEE,0xCE,0xCF,0xEE,0xEE,0xEF,0xCF,0xEE,0xCE,
    0xEE,0xCE,0xEE,0xCF,0xEF,0xEE,0xEF,0xCE,0xEE,0xEE,0xCF,0xEE,0xCF,0xEE,0xEE,0xCF,
    0xEF,0xCE,0xCF,0xEE,0xEF,0xEE,0xEE,0xEE,0xEE,0xEF,0xEE,0xCF,0xCF,0xEF,0xEE,0xCE,
    0xEF,0xEF,0xEF,0xEF,0xCE,0xEF,0xEE,0xEF,0xCF,0xEF,0xCF,0xCF,0xCE,0xCE,0xCE,0xCF,
    0xCF,0xEF,0xCE,0xEE,0xCF,0xEE,0xEF,0xCE,0xCE,0xCE,0xEF,0xEF,0xCF,0xCF,0xEE,0xEE,
    0xEE,0xCE,0xCF,0xCE,0xCE,0xCF,0xCE,0xEE,0xEF,0xEE,0xEF,0xEF,0xCF,0xEF,0xCE,0xCE,
    0xEF,0xCE,0xEE,0xCE,0xEF,0xCE,0xCE,0xEE,0xCF,0xCF,0xCE,0xCF,0xCF};

// Clock Mode.
UInt8 clockModeValue[] = {0x6B, 0x6C, 0x6D, 0x6E, 0x6F};

// Define XBee WiFi's AT commands.
static char atCmd[][3] = {
    // NOTES: [R] - read only, [R/W] = read/write, [s] - string, [b] - binary number, [sb] - string or binary number
    /* xbData */              "\0\0",/* [Wb] write data stream */
    /* xbMacHigh */           "SH",  /* [Rb] XBee's Mac Address (highest 16-bits) */
    /* xbMacLow */            "SL",  /* [Rb] XBee's Mac Address (lowest 32-bits) */
    /* xbSSID */              "ID",  /* [Rs/Ws] SSID (0 to 31 printable ASCII characters) */
    /* xbIPAddr */            "MY",  /* [Rb* /Wsb] XBee's IP Address (32-bits; IPv4); *Read-only in DHCP mode */
    /* xbIPMask */            "MK",  /* [Rb* /Wsb] XBee's IP Mask (32-bits); *Read-only in DHCP mode */
    /* xbIPGateway */         "GW",  /* [Rb* /Wsb] XBee's IP Gateway (32-bits); *Read-only in DHCP mode */
    /* xbIPPort */            "C0",  /* [Rb/Wb] Xbee's UDP/IP Port (16-bits) */
    /* xbIPDestination */     "DL",  /* [Rb/Wsb] Xbee's serial-to-IP destination address (32-bits; IPv4) */
    /* xbNodeID */            "NI",  /* [Rs/Ws] Friendly node identifier string (20 printable ASCII characters) */
    /* xbMaxRFPayload */      "NP",  /* [Rb] Maximum RF Payload (16-bits; in bytes) */
    /* xbPacketingTimeout */  "RO",  /* [Rb/Wb] Inter-character silence time that triggers packetization (8-bits; in character times) */
    /* xbIO2Mode */           "D2",  /* [Rb/Wb] Designated reset pin (3-bits; 0=Disabled, 1=SPI_CLK, 2=Analog input, 3=Digital input, 4=Digital output low, 5=Digital output high) */
    /* xbIO4Mode */           "D4",  /* [Rb/Wb] Designated serial hold pin (3-bits; 0=Disabled, 1=SPI_MOSI, 2=<undefined>, 3=Digital input, 4=Digital output low, 5=Digital output high) */
    /* xbOutputMask */        "OM",  /* [Rb/Wb] Output mask for all I/O pins (each 1=output pin, each 0=input pin) (15-bits on TH, 20-bits on SMT) */
    /* xbOutputState */       "IO",  /* [Rb/Wb] Output state for all I/O pins (each 1=high, each 0=low) (15-bits on TH, 20-bits on SMT).  Period affected by updIO2Timer */
    /* xbIO2Timer */          "T2",  /* [Rb/Wb] I/O 2 state timer (100 ms units; 0x0..0x1770) */
    /* xbIO4Timer */          "T4",  /* [Rb/Wb] I/O 4 state timer (100 ms units; 0x0..0x1770) */
    /* xbSerialMode */        "AP",  /* [Rb/Wb] Serial mode (0=Transparent, 1=API wo/Escapes, 2=API w/Escapes) */
    /* xbSerialBaud */        "BD",  /* [Rb/Wb] serial baud rate (0x1=2400, 0x2=4800, 0x3=9600, 0x4=19200, 0x5=38400, 0x6=57600, 0x7=115200, 0x8=230400, 0x9=460800, 0xA=921600) */
    /* xbSerialParity */      "NB",  /* [Rb/Wb] serial parity (0x0=none, 0x1=even, 0x2=odd) */
    /* xbSerialStopBits */    "SB",  /* [Rb/Wb] serial stop bits (0x0=one stop bit, 0x1=two stop bits) */
    /* xbRTSFlow */           "D6",  /* [Rb/Wb] RTS flow control pin (3-bits; 0=Disabled, 1=RTS Flow Control, 2=<undefined>, 3=Digital input, 4=Digital output low, 5=Digital output high) */
    /* xbSerialIP */          "IP",  /* [Rb/Wb] Protocol for serial service (0=UDP, 1=TCP) */
    /* xbFirmwareVer */       "VR",  /* [Rb] Firmware version.  Nibbles ABCD; ABC = major release, D = minor release.  B = 0 (standard release), B > 0 (variant release) (16-bits) */
    /* xbHardwareVer */       "HV",  /* [Rb] Hardware version.  Nibbles ABCD; AB = module type, CD = revision (16-bits) */
    /* xbHardwareSeries */    "HS",  /* [Rb] Hardware series. (16-bits?) */
    /* xbChecksum */          "CK"   /* [Rb] current configuration checksum (16-bits) */
};

typedef enum {serialUDP = 0, serialTCP = 1} ipModes;
typedef enum {pinDisabled= 0, pinEnabled = 1, pinAnalog = 2, pinInput = 3, pinOutLow = 4, pinOutHigh = 5} ioKinds;
typedef enum {transparentMode = 0, apiWoEscapeMode = 1, apiWEscapeMode = 2} serialModes;
typedef enum {parityNone = 0, parityEven = 1, parityOdd = 2} serialParity;
typedef enum {stopBits1 = 0, stopBits2 = 1} stopBits;

typedef struct {
    // Application Header
    UInt16 number1;							// Can be any random number.
    UInt16 number2;							// Must be number1 ^ 0x4242
    UInt8 packetID;							// Reserved (use 0)
    UInt8 encryptionPad;					// Reserved (use 0)
    UInt8 commandID;						// 0x00 = Data, 0x02 = Remote Command, 0x03 = General Purpose Memory Command, 0x04 = I/O Sample
    UInt8 commandOptions;					// Bit 0 : Encrypt (Reserved), Bit 1 : Request Packet ACK, Bits 2..7 : (Reserved)
    // Command Data
    UInt8 frameID;							// 1
    UInt8 configOptions;					// 0 = Queue command only; must follow with AC command to apply changes, 2 = Apply Changes immediately
    UInt16 atCommand;						// Command Name - Two ASCII characters that identify the AT command
    UInt8 tParamValue[];					// [Array] (if present) is value to set in the given command, otherwise, command is queried.
} txPacket, *txPacketPtr;


@interface Loader () {
    BOOL cancelling;						// YES if we need to cancel the laod, else NO.
    BOOL gettingDeviceName;					// Flag indicating we are processing a call to getDeviceName.
    int maxDataSize;						// Maximum size allowed for data (payload) of packet; must be a multiple of 4.
    pthread_mutex_t mutex;					// Semaphore used for thread safety.
    BOOL randInitialized;					// Have we seeded the random number generator?
    BOOL reportedError;						// Did we report an erro when doing the most recent load?
    int totalPackets;						// The number of packets to load.
    double udpRoundTrip;					// The round trip time from sending to receiving a reply on the last successful call to transmitAppUDP:expectMultiple:autoRetry:err:.
    double udpMaxRoundTrip;					// The maximum observed udpRoundTrip.
}

@property (nonatomic, retain) NSMutableArray *deviceList;		// A list of available XBee Devices. An array of TXBee objects.
@property (nonatomic, retain) NSData *fileBytes;				// The data in the file.
@property (nonatomic, retain) NSData *txBuff;					// The buffer of data to transmit.
@property (nonatomic, retain) GCDAsyncUdpSocket *udpSocket;		// A UDP socket manager object.
@property (nonatomic, retain) GCDAsyncUdpSocket *udpDataSocket;	// A UDP socket manager object.
@property (nonatomic, retain) UDPDataBuffer *udpStack;			// A UDP FIFO data buffer containing unprocessed UDP packets.
@property (nonatomic, retain) TXBee *xBee;						// The active XBee component.

@end

@implementation Loader

@synthesize delegate;
@synthesize deviceList;
@synthesize fileBytes;
@synthesize loaderDomain;
@synthesize txBuff;
@synthesize udpDataSocket;
@synthesize udpSocket;
@synthesize udpStack;
@synthesize xBee;

/*!
 * Convert a baud rate to an ZBee baud rate index.
 *
 * @param baud		The baud rate.
 *
 * @return			The XBee baud rate index; one of:
 *						1 = 2400 bps
 *						2 = 4800
 *						3 = 9600
 *						4 = 19200
 *						5 = 38400
 *						6 = 57600
 *						7 = 115200
 *						8 = 230400
 *						9 = 460,800
 *						10 = 921,600
 *					Unrecognized baud rates are retunred unmodified.
 */

- (int) baudToXBeeIndex: (int) baud {
    int index = baud;
    switch (baud) {
        case 2400: index = 1; break;
        case 4800: index = 2; break;
        case 9600: index = 3; break;
        case 19200: index = 4; break;
        case 38400: index = 5; break;
        case 57600: index = 6; break;
        case 115200: index = 7; break;
        case 230400: index = 8; break;
        case 460800: index = 9; break;
        case 921600: index = 10; break;
    }
    return index;
}

/*!
 * Cancel the current laod operation. This has no effect if a load is not in progress.
 */

- (void) cancel {
    cancelling = YES;
}

/*!
 * Close the current connection. This can be called multiple times with no ill effect.
 */

- (void) close {
    if (udpDataSocket != nil) {
        [udpDataSocket close];
        udpDataSocket = nil;
    }
    if (udpSocket != nil) {
        [udpSocket close];
        udpSocket = nil;
    }
    
    if (!reportedError)
	    [self performSelectorOnMainThread: @selector(loaderComplete) withObject: nil waitUntilDone: NO];
}

/*!
 * Return the singleton instance of the loader class, creating one if it does not already exist.
 *
 * @return		The singleton instance of this class.
 */

+ (Loader *) defaultLoader {
    if (this == nil) {
        this = [[Loader alloc] init];
    }
    return this;
}

/*!
 * Dumps a data packet in binary format.
 *
 * This is used for debuggong transmissions to and from the XBee. Set PACKET_DUMP to 1 to include this method in the
 * build, or to 0 to eliminate it.
 *
 * @param packet	The packet to dump.
 * @param title		A string identifying the packet being dumped. Pass nil if no title is needed.
 */

#if PACKET_DUMP
- (void) dump: (NSData *) packet title: (NSString *) title {
    if (title)
        printf("%s", [title UTF8String]);
    if (packet == nil)
        printf("\nnil packet\n");
    else {
        for (int i = 0; i < packet.length; ++i) {
            if (i%16 == 0)
                printf("\n%04X:", i);
            printf(" %02X", ((UInt8 *) packet.bytes)[i]);
        }
        printf("\n");
    }
}
#endif

/*!
 * Returns serial timeout adjusted for recent communication delays; minimum MinSerTimeout s, maximum SerTimeout s.
 *
 * @return		The timeout delay, in seconds.
 */

- (float) dynamicSerTimeout {
    float timeout = udpMaxRoundTrip*DYNAMIC_WAIT_FACTOR;
    if (SER_TIMEOUT < timeout)
        timeout = SER_TIMEOUT;
    if (MIN_SER_TIMEOUT > timeout)
        timeout = MIN_SER_TIMEOUT;
    if (timeout == 0)
        timeout = 8.0;
    return timeout;
}

/*!
 * Validate necessary XBee configuration; set attributes if needed.
 *
 * @param err		Set to the error if one occurred, else unchanged.
 *
 * @return			YES for a successful completion, else NO. Check err for any error codes.
 */

- (BOOL) enforceXBeeConfiguration: (NSError **) err {
    // Dump anything in the UDP buffer. We are not expecting anything, so if something is there, it's random leak from the serial port.
    while ([udpStack pull: nil udpAddress: nil udpTime: nil]);
    
    // Is the configuration known and valid?
    BOOL result = (xBee.cfgChecksum != VALUE_UNKNOWN) && [self validate: xbChecksum value: xBee.cfgChecksum readOnly: YES err: err];
    
    if (!result) {
        if (!*err) xBee.firmwareVersion = [self getItem: xbFirmwareVer err: err];				// Get the firmware version
        if (!*err) [self validate: xbSerialIP value: serialUDP readOnly: xBee.firmwareVersion < 0x2023 err: err]; // Ensure XBee's Serial Service uses UDP packets
        if (!*err) [self validate: xbIPDestination string: [Common getIPAddress] readOnly: NO err: err];	// Ensure Serial-to-IP destination is us (our IP)
        if (!*err) [self validate: xbOutputMask value: 0x7FFF readOnly: NO err: err];			// Ensure output mask is proper (default, in this case)
        if (!*err) [self validate: xbRTSFlow value: pinEnabled readOnly: NO err: err];			// Ensure RTS flow pin is enabled (input)
        if (!*err) [self validate: xbRTSFlow value: pinEnabled readOnly: NO err: err];			// Ensure RTS flow pin is enabled (input)
        if (!*err) [self validate: xbIO4Mode value: pinOutLow readOnly: NO err: err];			// Ensure serial hold pin is set to output low
        if (!*err) [self validate: xbIO2Mode value: pinOutHigh readOnly: NO err: err];			// Ensure reset pin is set to output high
        if (!*err) [self validate: xbIO4Timer value: 2 readOnly: NO err: err];					// Ensure serial hold pin's timer is set to 200 ms
        if (!*err) [self validate: xbIO2Timer value: 1 readOnly: NO err: err];					// Ensure reset pin's timer is set to 100 ms
        if (!*err) [self validate: xbSerialMode value: transparentMode readOnly: xBee.firmwareVersion < 0x2023 err: err]; // Ensure Serial Mode is transparent
        if (!*err) [self validate: xbSerialBaud value: [self baudToXBeeIndex: INITIL_BAUD] readOnly: NO err: err]; // Ensure baud rate is set to initial speed
        if (!*err) [self validate: xbSerialParity value: parityNone readOnly: NO err: err];		// Ensure parity is none
        if (!*err) [self validate: xbSerialStopBits value: stopBits1 readOnly: NO err: err];	// Ensure stop bits is 1
        if (!*err) [self validate: xbPacketingTimeout value: 3 readOnly: NO err: err];			// Ensure packetization timout is 3 character times
		if (!*err) xBee.cfgChecksum = [self getItem: xbChecksum err: err];						// Record new configuration checksum
        result = *err == nil;
    }
    return result;
}

/*!
 * Build and return an error for the specified error number.
 *
 * @param errNum	The error number.
 */

- (NSError *) getError: (int) errNum {
    return [self getError: errNum localizedFailureReason: nil];
}

/*!
 * Build and return an error for the specified error number.
 *
 * @param errNum					The error number.
 * @param localizedFailureReason	The localized description; pass nil for errors that don't need to customize this value.
 */

- (NSError *) getError: (int) errNum localizedFailureReason: (NSString *) localizedFailureReason {
    NSString *localizedDesciption;
    NSString *localizedRecoverySuggestion;
    
    switch (errNum) {
        case 1:
            localizedDesciption = @"No Response.";
            localizedFailureReason = @"A UDP command was sent to the XBee, but there was no response.";
            localizedRecoverySuggestion = @"Make sure the reset wire and serial wires from the XBee to the Propeller are correct. Make sure both have power.";
            break;
            
        case 2:
            localizedDesciption = @"Error.";
            localizedFailureReason = @"A UDP command was sent to the XBee, which did not return a response.";
            localizedRecoverySuggestion = @"Make sure the reset wire and serial wires from the XBee to the Propeller are correct. Make sure both have power.";
            break;
            
        case 3:
            localizedDesciption = @"Error.";
            // localizedFailureReason passed by caller.
            localizedRecoverySuggestion = @"Make sure the reset wire and serial wires from the XBee to the Propeller are correct. Make sure both have power.";
            break;
            
        case 4:
            localizedDesciption = @"Unrecognized Response";
            localizedFailureReason = @"The response to the handshake was not what was expected.";
            localizedRecoverySuggestion = @"Make sure you are connecting to a Propeller board.";
            break;
            
        case 5:
            localizedDesciption = @"Unexpected Version";
            // localizedFailureReason passed by caller.
            localizedRecoverySuggestion = @"Make sure you are connecting to a v1 Propeller board.";
            break;
            
        case 6:
            localizedDesciption = @"No Response";
            localizedFailureReason = @"No connection response from Propeller!";
            localizedRecoverySuggestion = @"Make sure you are connecting to a Propeller board.";
            break;
            
        case 7:
            localizedDesciption = @"No Response";
            localizedFailureReason = @"No loader checksum response!";
            localizedRecoverySuggestion = @"Make sure you are connecting to a Propeller board.";
            break;
            
        case 8:
            localizedDesciption = @"Invalid Checksum";
            localizedFailureReason = @"Loader failed checksum test.";
            localizedRecoverySuggestion = @"Make sure you are connecting to a Propeller board.";
            break;
            
        case 9:
            localizedDesciption = @"No Ready Signal";
            localizedFailureReason = @"No \"Ready\" signal from loader.";
            localizedRecoverySuggestion = @"Make sure you are connecting to a Propeller board.";
            break;
            
        case 10:
            localizedDesciption = @"Invalid Ready Signal";
            localizedFailureReason = @"Loader's \"Ready\" signal unrecognized.";
            localizedRecoverySuggestion = @"Make sure you are connecting to a Propeller board.";
            break;
            
        case 11:
            localizedDesciption = @"Connection Failure";
            localizedFailureReason = @"Packet transmission failed.";
            localizedRecoverySuggestion = @"Make sure the Propeller board and XBee are still powered on.";
            break;
            
        case 12:
            localizedDesciption = @"Checksum Failure";
            localizedFailureReason = @"RAM Checksum Failure.";
            localizedRecoverySuggestion = @"Make sure the Propeller board and XBee are still powered on.";
            break;
            
        case 13:
            localizedDesciption = @"Launch Failure";
            localizedFailureReason = @"Communication failed.";
            localizedRecoverySuggestion = @"Make sure the Propeller board and XBee are still powered on.";
            break;
            
        case 14:
            localizedDesciption = @"Connection Failure";
            localizedFailureReason = @"Packet transmission failed.";
            localizedRecoverySuggestion = @"Make sure the Propeller board and XBee are still powered on.";
            break;
            
        case 15:
            localizedDesciption = @"Checksum Failure";
            localizedFailureReason = @"EEPROM programming failure.";
            localizedRecoverySuggestion = @"Make sure the Propeller board and XBee are still powered on.";
            break;
    }

    return [NSError errorWithDomain: loaderDomain
                               code: errNum
                           userInfo: [NSDictionary dictionaryWithObjectsAndKeys:
                                      localizedDesciption,
                                      NSLocalizedDescriptionKey,
                                      localizedFailureReason,
                                      NSLocalizedFailureReasonErrorKey,
                                      localizedRecoverySuggestion,
                                      NSLocalizedRecoverySuggestionErrorKey,
                                      nil]];
}

/*!
 * Gets a 4-byte value from a byte array.
 *
 * @param bytes		The array from which to get the value.
 * @param offset	The location for the first byte.
 *
 * @return			The 4 byte value to place in the array.
 */

- (int) hostInitializedValue: (UInt8 *) bytes offset: (int) offset {
    int value = 0;
	for (int i = 0; i < 4; ++i)
        value = value | ((bytes[offset + i] & 0x00FF) << i*8);
    return value;
}

/*!
 * Places a 4-byte value in a byte array.
 *
 * @param bytes		The array in which to place the value.
 * @param offset	The location for the first byte.
 * @param value		The 4 byte value to place in the array.
 */

- (void) patchLoaderLongValue: (UInt8 *) bytes offset: (int) offset value: (int) value {
	for (int i = 0; i < 4; ++i)
        bytes[offset + i] = (value >> (i*8)) & 0xFF;
}

/*!
 * Calls generateLoaderPacket:packetID:clockSpeed:clockMode: with clockSpeed = 0 and clockMode = 0.
 *
 * @param loaderType	The type of the loader.
 * @param packetID		The packet ID number for this packet.
 */

- (void) generateLoaderPacket: (typeLoaderType) loaderType 
                     packetID: (int) packetID 
{
    [self generateLoaderPacket: loaderType packetID: packetID clockSpeed: 0 clockMode: 0];
}

/*!
 * Generate a single packet (in txBuf) that contains a portion of the Micro Boot Loader (IP_Loader.spin) 
 * according to loaderType, clockSpeed and clockMode.
 *
 * Initial call should request loaderType of ltCore, packetID equal to target application's packet count, 
 * and a clockSpeed and clockMode optionally equal to target application's system clock frequency and 
 * clock mode.  Later calls should request other loaderTypes with the actual packetID of the pacekt the 
 * loader portion will be delivered inside of and omitting the ClockSpeed and ClockMode.
 *
 * If LoaderType is ltCore...
 * 	- target application's total packet count must be included in PacketID.
 *	- target application's system clock speed must be included in ClockSpeed.
 *	- target application's system clock mode must be included in ClockMode.
 * 	- generated packet contains the Propeller handshake, timing templates, and core code from the Propeller
 *		Loader Image (IP_Loader.spin), encoded in an optimized format (3, 4, or 5 bits per byte; 7 to 11
 *		bytes per long).
 *
 * Note: optimal encoding means, for every 5 contiguous bits in Propeller Application Image (LSB first) 3, 4, 
 * or 5 bits can be translated to a byte.  The process requires 5 bits input (ie: indexed into the PDSTx array)
 * and gets a byte out that contains the first 3, 4, or 5 bits encoded in the Propeller Download stream format. 
 * The 2nd dimention of the PDSTx array contains the number of bits acutally encoded.  If less than 5 bits were 
 * translated, the remaining bits lead the next 5-bit translation unit input to the translation process.
 *
 * If loaderType is not ltCore...
 *	- PacketIDs should be less than 0 for this type of packet in order to work with the Micro Boot Loader core.
 *	- ClockSpeed and ClockMode can be omitted.
 *	- generated packet is a snippet of loader code aligned to be executable from inside the Core's packet 
 *		buffer.  This snippet is in raw form (it is not encoded) and should be transmitted as such.
 *
 * @param loaderType	The type of the loader.
 * @param packetID		The packet ID number for this packet.
 * @param clockSpeed	The packet ID number for this packet.
 * @param clockMode		The packet ID number for this packet.
 */

- (void) generateLoaderPacket: (typeLoaderType) loaderType 
                     packetID: (int) packetID 
                   clockSpeed: (int) clockSpeed 
                    clockMode: (int) clockMode 
{
    self.txBuff = nil;
    
    if (loaderType == ltCore) {
        // Generate specially-prepared stream of Micro Boot Loader's core (with handshake, timing templates, and
        // host-initialized timing.
        
        // Reserve memory for Raw Loader Image.
        int rawSize = (RAW_LOADER_IMAGE_SIZE + 3)/4;
        
        // Reserve LoaderImage space for RawLoaderImage data plus 1 extra byte to accommodate generation routine.
        UInt8 *loaderImage = calloc(rawSize*4 + 1, 1);
        
        // Reserve loaderStream space for maximum-sized download stream.
        UInt8 *loaderStream = malloc(rawSize*4*11);
        
        // Prepare Loader Image with patched clock metrics and host-initialized values.
        //
        // Copy raw loader image to LoaderImage (for adjustments and processing).
        memcpy(loaderImage, rawLoaderImage, RAW_LOADER_IMAGE_SIZE);
        
        // Set booter's clock speed.
        [self patchLoaderLongValue: loaderImage offset: 0 value: clockSpeed];
        
        // Set booter's clock mode.
        loaderImage[4] = clockMode;
        
        // Booter's clock selection bits.
        int offset = rawSize*4 + RAW_LOADER_INIT_OFFSET;
        [self patchLoaderLongValue: loaderImage offset: offset + 0 value: (int) (clockMode & 0x07)];
        
        // Initial bit time.
        [self patchLoaderLongValue: loaderImage offset: offset + 4 value: (int) (clockSpeed/INITIL_BAUD + 0.5)];
        
        // Final bit time.
        [self patchLoaderLongValue: loaderImage offset: offset + 8 value: (int) (clockSpeed/FINAL_BAUD + 0.5)];
        
        // 1.5x Final Bit Time minus maximum start bit sense error.
        [self patchLoaderLongValue: loaderImage offset: offset + 12 value: (int) trunc(1.5*clockSpeed/FINAL_BAUD - MAX_RX_SENSE_ERROR + 0.5)];
        
        // Failsafe Timeout (seconds-worth of Loader's Receive loop iterations).
        [self patchLoaderLongValue: loaderImage offset: offset + 16 value: (int) trunc(2.0*clockSpeed/(3*4) + 0.5)];
        
        // EndOfPacket Timeout (2 bytes worth of Loader's Receive loop iterations).
        [self patchLoaderLongValue: loaderImage offset: offset + 20 value: (int) trunc((2.0*clockSpeed/FINAL_BAUD)*(10.0/12.0) + 0.5)];
        
        // Minimum EEPROM Start/Stop Condition setup/hold time (400 KHz = 1/0.6 µS); Minimum 14 cycles.
        int value = trunc(clockSpeed*SSSH_TIME) + 0.5;
        if (value < 14)
            value = 14;
        [self patchLoaderLongValue: loaderImage offset: offset + 24 value: value];
        
        // Minimum EEPROM SCL high time (400 KHz = 1/0.6 µS); Minimum 14 cycles.
        value = trunc(clockSpeed*SCL_HIGH_TIME) + 0.5;
        if (value < 14)
            value = 14;
        [self patchLoaderLongValue: loaderImage offset: offset + 28 value: value];

        // Minimum EEPROM SCL low time (400 KHz = 1/1.3 µS); Minimum 26 cycles.
        value = trunc(clockSpeed*SCL_LOW_TIME) + 0.5;
        if (value < 26)
            value = 26;
        [self patchLoaderLongValue: loaderImage offset: offset + 32 value: value];
        
        // First Expected Packet ID; total packet count.
        [self patchLoaderLongValue: loaderImage offset: offset + 36 value: packetID];
        
        // Recalculate and update checksum so low byte of checksum calculates to 0.
        int checksum = 0;
        loaderImage[5] = 0;
        for (int i = 0; i < rawSize*4; ++i)
            checksum += loaderImage[i];
        for (int i = 0; i < INIT_CALL_FRAME_SIZE; ++i)
            checksum += initCallFrame[i];
        loaderImage[5] = 256 - (checksum & 0xFF);
        
        // Generate Propeller Loader Download Stream from adjusted LoaderImage (above); Output delivered to LoaderStream and LoaderStreamSize.
        int bCount = 0;
        int loaderStreamSize = 0;
        while (bCount < rawSize*4*8) {
        	int bitsIn = rawSize*4*8 - bCount;
            if (bitsIn > 5)
                bitsIn = 5;
            int mask = 0;
            for (int i = 0; i < bitsIn; ++i)
                mask = (mask << 1) | 1;
            int bValue = ((loaderImage[bCount/8] >> (bCount%8)) + (loaderImage[bCount/8 + 1] << (8 - bCount%8))) & mask;
            
            loaderStream[loaderStreamSize] = PDSTx[bValue][bitsIn - 1][DT_TX];
            ++loaderStreamSize;
            bCount += PDSTx[bValue][bitsIn - 1][DT_BITS];
        }

        // Prepare loader packet; contains handshake and Loader Stream.
        int txBuffLength = TX_HANDSHAKE_LENGTH + 11 + loaderStreamSize;
        UInt8 *byteBuff = malloc(txBuffLength);
        if (txBuffLength > maxDataSize)
            printf("Developer Error: Initial packet is too large (%d bytes)!", txBuffLength);
        memcpy(byteBuff, txHandshake, TX_HANDSHAKE_LENGTH);
        
        txBuffLength = TX_HANDSHAKE_LENGTH;
        for (int i = 0; i <= 10; ++i) {
            byteBuff[txBuffLength++] = 0x92 | (i == 10 ? 0x60 : 0x00) | (rawSize & 1) | ((rawSize & 2) << 2) | ((rawSize & 4) << 4);
            rawSize = rawSize >> 3;
        }
        
        memcpy(byteBuff + txBuffLength, loaderStream, loaderStreamSize);
        self.txBuff = [NSData dataWithBytes: byteBuff length: txBuffLength + loaderStreamSize];
        
        free(byteBuff);
        free(loaderImage);
        free(loaderStream);
    } else {
        // Prepare loader's executable packet.
        //
        // Note that the packet ID is stuffed into the first 4 bytes, then 4 bytes are skipped. These are for the transmission ID field,
        // which will be filled in by transmitPacket.
        switch (loaderType) {
            case ltCore:
                // Handled above.
                break;
                
            case ltVerifyRAM: {
                UInt8 *byteBuff = malloc(8 + VERIFY_RAM_LENGTH);
                [self patchLoaderLongValue: byteBuff offset: 0 value: packetID];
                memcpy(byteBuff + 8, verifyRAM, VERIFY_RAM_LENGTH);
                self.txBuff = [NSData dataWithBytes: byteBuff length: VERIFY_RAM_LENGTH + 8];
                free(byteBuff);
                break;
            }
                
            case ltProgramEEPROM: {
                UInt8 *byteBuff = malloc(8 + VERIFY_EEPROM_LENGTH);
                [self patchLoaderLongValue: byteBuff offset: 0 value: packetID];
                memcpy(byteBuff + 8, verifyEEPROM, VERIFY_EEPROM_LENGTH);
                self.txBuff = [NSData dataWithBytes: byteBuff length: VERIFY_EEPROM_LENGTH + 8];
                free(byteBuff);
                break;
            }
                
            case ltReadyToLaunch: {
                UInt8 *byteBuff = malloc(8 + READY_TO_LAUNCH_LENGTH);
                [self patchLoaderLongValue: byteBuff offset: 0 value: packetID];
                memcpy(byteBuff + 8, readyToLaunch, READY_TO_LAUNCH_LENGTH);
                self.txBuff = [NSData dataWithBytes: byteBuff length: READY_TO_LAUNCH_LENGTH + 8];
                free(byteBuff);
                break;
            }
                
            case ltLaunchNow: {
                UInt8 *byteBuff = malloc(8 + LAUNCH_NOW_LENGTH);
                [self patchLoaderLongValue: byteBuff offset: 0 value: packetID];
                memcpy(byteBuff + 8, launchNow, LAUNCH_NOW_LENGTH);
                self.txBuff = [NSData dataWithBytes: byteBuff length: LAUNCH_NOW_LENGTH + 8];
                free(byteBuff);
                break;
            }
        }
    }
}

/*!
 * Generate reset pulse.
 *
 * @param err	Set to the error if one occurred, else unchanged.
 */

- (void) generateResetSignal: (NSError **) err {
    if ([self enforceXBeeConfiguration: err]) {
        // Start reset pulse (low) and serial hold (high).
        [self setAttribute: xbOutputState value: 0x0010 err: err];
    }
}

/*!
 * Set up this object.
 *
 * @return The new object.
 */

- (id) init {
    self = [super init];
    
    if (self) {
        // Set the error domain.
        self.loaderDomain = @"Loader";
        
        // Initialize a semiphore.
        [self initMutex];
        
        // Set up a UDP buffer.
        udpStack = [[UDPDataBuffer alloc] init];
    }
    
    return self;
}

/*!
 * Set up the semiphore used for obtaining thread locks.
 */

- (void) initMutex {
    if (!mutexInitialized) {
        mutexInitialized = TRUE;
        pthread_mutex_init(&mutex, NULL);
    }
}

/*!
 * Initiate loading of a new file.
 *
 * @param binary		The path name of the binary file to load.
 * @param eeprom		YES to burn to EPROM, or NO to burn only load to RAM.
 * @param theXBee		Information about the XBee device.
 * @param loadAttempts	The maximum number of times to attempt a load before giving up.
 * @param error			If an error is encountered during the laod, it is
 */

- (void) load: (NSString *) binary
       eeprom: (BOOL) eeprom
         xBee: (TXBee *) theXBee
 loadAttempts: (int) loadAttempts
        error: (NSError **) error
{
    // For very low values of SLEEP_TIME, the network test object can have two active calls to this method. That is
    // a Very Bad Thing. Prevent it with a thread lock.
    pthread_mutex_lock(&mutex);
    
    // We're not cacelling yet.
    cancelling = NO;
    
    // No errors, yet.
    reportedError = NO;
    
    // Save the information about the device.
    self.xBee = theXBee;
    
    // Do setup for a load.
    maxDataSize = DEFAULT_MAX_DATA_SIZE;
    udpMaxRoundTrip = 0.0;
    
    // Load the propeller application file that will be sent.
    fileBytes = [NSMutableData dataWithData: [NSData dataWithContentsOfFile: binary]];
#if DEBUG_ME
    printf("Loaded %d bytes of program data.\n", (int) fileBytes.length);
#endif
    
    // Determine number of required packets for target application image; value becomes first Packet ID.
    totalPackets = (int) (1 + ((fileBytes.length + 3)/4)*4/(maxDataSize - HEADER_SIZE));
    int packetID = totalPackets;
    
    // Calculate the target application checksum (used for RAM Checksum confirmation).
    int checksum = 0;
    for (int i = 0; i < fileBytes.length; ++i)
        checksum += ((UInt8 *) fileBytes.bytes)[i];
    for (int i = 0; i < INIT_CALL_FRAME_SIZE; ++i)
        checksum += initCallFrame[i];
    
    // Try connecting up to loadAttempts times.
    BOOL acknowledged = NO;
    int retry = loadAttempts;
    NSError *err = nil;
    do {
        err = nil;
        NSData *rxBuff;
        
        [self performSelectorOnMainThread: @selector(loaderProgress:) withObject: [NSNumber numberWithFloat: 0.0] waitUntilDone: NO];
        
        if (!cancelling) {
            // Generate initial packet (handshake, timing templates, and Propeller Loader's Download Stream) all stored in TxBuf.
            [self generateLoaderPacket: ltCore packetID: totalPackets clockSpeed: CLOCK_SPEED clockMode: clockModeValue[CLOCK_MODE_INDEX]];
            [self generateResetSignal: &err];
            
            // Set up the UDP data socket. This is the one that will receive data back from the Propeller board, and be used for
            // serial output.
            if (!err && !udpDataSocket) {
                udpDataSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate: self delegateQueue: dispatch_get_main_queue()];
                [udpDataSocket bindToPort: SERIAL_PORT error: &err];
                if (err == nil)
                    [udpDataSocket beginReceiving: &err];
            }
        }
        
        if (!err && !cancelling) {
            // Send initial packet and wait for 200 ms (reset period) + serial transfer time + 20 ms (to position timing templates)
            [self setStateInDelegate: @"Sending initial packet."];
#if PACKET_DUMP
            [self dump: txBuff title: @"Initial packet: (via sendUDP)"];
#endif
            if ([self sendUDP: txBuff useAppService: YES autoRetry: NO err: &err])
                [NSThread sleepForTimeInterval: (200 + txBuff.length*10.0*1000.0/INITIL_BAUD + 20)/1000.0];
        }

        if (!err && !cancelling) {
            // Prep and send timing templates, then wait for serial transfer time.
            [self setStateInDelegate: @"Getting serial rate."];
            UInt8 *txBytes = malloc(MAX_DATA_SIZE);
            memset(txBytes, 0xF9, MAX_DATA_SIZE);
            NSData *txData = [NSData dataWithBytes: txBytes length: MAX_DATA_SIZE];
            free(txBytes);
            if ([self sendUDP: txData useAppService: YES autoRetry: NO err: &err])
                [NSThread sleepForTimeInterval: txData.length*10.0/INITIL_BAUD];
#if PACKET_DUMP
            // Time critical--do not dump.
            printf("\nSending timing template (%d bytes of 0xF9)\n", MAX_DATA_SIZE);
#endif

            // Flush receive buffer and get handshake response. This loops if a response was incorrect, flushing the buffer 
            // of junk responses from a noisy connection.
            if (!err && !cancelling) {
                do {
                    // Get the UDP response.
                    if ([self receiveUDP: &rxBuff timeout: SER_TIMEOUT]) {
#if PACKET_DUMP
                        // Time critical--do not dump.
                        printf("\nReceived hardware version packet of %d bytes.\n", rxBuff.length);
#endif
                        if (rxBuff.length == 129) {
                            for (int i = 0; i < 124; ++i)
                                if (((UInt8 *) rxBuff.bytes)[i] != rxHandshake[i])
                                    err = [self getError: 4];
                            
                            // Parse hardware version.
                            int fVersion = 0;
                            for (int i = 125; i <= 128; ++i)
                                fVersion = (fVersion >> 2 & 0x3F) | ((((UInt8 *) rxBuff.bytes)[i] & 0x01) << 6) | ((((UInt8 *) rxBuff.bytes)[i] & 0x20) << 2);
                            if (fVersion != 1)
                                err = [self getError: 5 localizedFailureReason: [NSString stringWithFormat: @"Expected Propeller v1, but found Propeller v%d", fVersion]];
                        }
                    } else
                        err = [self getError: 6];
                } while (err == nil && rxBuff.length != 129);
            }
            
            // Receive Loader RAM Checksum Response
            if (!err && !cancelling) {
                if (![self receiveUDP: &rxBuff timeout: [self dynamicSerTimeout]] || rxBuff.length != 1)
                    err = [self getError: 7];
                else if (((UInt8 *) rxBuff.bytes)[0] != 0x00FE)
                    err = [self getError: 8];
#if PACKET_DUMP
                [self dump: rxBuff title: @"\nChecksum response (via receiveUDP):"];
#endif

                // Notify delegates of any error.
                if (err && [delegate respondsToSelector: @selector(checksumFailure)])
                    [delegate checksumFailure];
            }
        }
        
        if (!err && !cancelling) {
            acknowledged = [self receiveUDP: &rxBuff timeout: [self dynamicSerTimeout]];
#if PACKET_DUMP
            [self dump: rxBuff title: @"\nHandshake response (via receiveUDP):"];
#endif
            if (!acknowledged || rxBuff.length != 8)
                err = [self getError: 9];
        }
        
        // Verify ready signal; ignore value of Transmission ID field.
        if (!err && !cancelling && ((UInt8 *) rxBuff.bytes)[0] != packetID)
            err = [self getError: 10];
        
        if (!err && !cancelling)
            [self validate: xbSerialBaud value: [self baudToXBeeIndex: FINAL_BAUD] readOnly: NO err: &err];

        // Show the progress.
        [self performSelectorOnMainThread: @selector(loaderProgress:) withObject: [NSNumber numberWithFloat: 1.0/(totalPackets + 1.0)] waitUntilDone: NO];

        // Transmit packetized target application.
        if (!err && !cancelling) {
            [self setStateInDelegate: @"Transmitting application."];
            int offset = 0;
            do {
                // Determine packet length; header + packet limit or remaining data length.
                int txBuffLength = 8 + (int) (maxDataSize - 8 < fileBytes.length - offset ? maxDataSize - 8 : fileBytes.length - offset);
                
                UInt8 *byteBuff = malloc(txBuffLength);
                [self patchLoaderLongValue: byteBuff offset: 0 value: packetID];
                memcpy(byteBuff + 8, ((UInt8 *) fileBytes.bytes) + offset, txBuffLength - 8);
                
                // Transmit packet (retransmit as necessary)
#if PACKET_DUMP
                printf("\nSend packet with packet ID %d (via transmitPacket):", packetID);
#endif
                int response = [self transmitPacket: byteBuff length: txBuffLength err: &err];
                if (response != packetID - 1)
                    err = [self getError: 11];
                
                offset += txBuffLength - 8;
                --packetID;
                free(byteBuff);
                
                // Show the progress.
                NSNumber *progress = [NSNumber numberWithFloat: (totalPackets - packetID + 1.0)/(totalPackets + 1.0)];
                [self performSelectorOnMainThread: @selector(loaderProgress:) withObject: progress waitUntilDone: NO];
            } while (packetID > 0 && err == nil);
        }
        
        // Send verify RAM command.
        if (!err && !cancelling) {
            [self setStateInDelegate: @"Verifying RAM."];
            packetID = 0;
            [self generateLoaderPacket: ltVerifyRAM packetID: packetID];
#if PACKET_DUMP
            printf("\nSend ltVerifyRAM with packet ID %d (via transmitPacket):", packetID);
#endif
            int checksumID = [self transmitPacket: (UInt8 *) txBuff.bytes length: (int) txBuff.length err: &err];
            if (checksumID != -checksum)
                err = [self getError: 12];
            
            // Further packet IDs are based on the checksum.
            packetID = -checksum;
        }

        // If needed, program for EEPROM.
        if (eeprom) {
            [self setStateInDelegate: @"Programming EEPROM"];
            
            // Send Program/Verify EEPROM command.
            [self generateLoaderPacket: ltProgramEEPROM packetID: packetID];
#if PACKET_DUMP
            printf("\nSend ltProgramEEPROM (via transmitPacket):");
#endif
            if ([self transmitPacket: (UInt8 *) txBuff.bytes 
                              length: (int) txBuff.length 
                      ignoreResponse: FALSE 
                       customTimeout: 8.0 
                                 err: &err] != -checksum*2) 
            {
                err = [self getError: 15];
            }
            packetID = -checksum*2;
        }

        // Send verified/launch command.
        if (!err && !cancelling) {
            [self generateLoaderPacket: ltReadyToLaunch packetID: packetID];
#if PACKET_DUMP
            printf("\nSend ltReadyToLaunch with packet ID %d (via transmitPacket):", packetID);
#endif
            if ([self transmitPacket: (UInt8 *) txBuff.bytes length: (int) txBuff.length err: &err] != packetID-1)
                err = [self getError: 13];
            --packetID;
        }
        
        // Send launch command.
        if (!err && !cancelling) {
            [self setStateInDelegate: @"Send launch command."];
            [self generateLoaderPacket: ltLaunchNow packetID: packetID];
            // Transmit last packet (Launch step 2) only once (no retransmission); ignoring any response.
#if PACKET_DUMP
            printf("\nSend ltLaunchNow with packet ID %d (via transmitPacket):", packetID);
#endif
            [self transmitPacket: (UInt8 *) txBuff.bytes 
                          length: (int) txBuff.length 
                  ignoreResponse: YES 
                   customTimeout: 0 
                             err: &err];
        }
        
        if (err != nil && !cancelling) {
            --retry;
            if (err && err.code == 1)
                cancelling = YES;
            if (retry == 0) {
                acknowledged = YES;
            } else {
                // Notify delegates of any error.
                if (err && [delegate respondsToSelector: @selector(loadFailure)])
                    [delegate loadFailure];
            }
        }
    } while (!acknowledged && !cancelling);
    [self setStateInDelegate: @"Waiting to load."];
    
    // Report any errors.
    if (err) {
        reportedError = YES;
        *error = err;
        [self performSelectorOnMainThread: @selector(loaderFatalError:) withObject: err waitUntilDone: NO];
    }
    
    // Reset the baud rate to the initial baud rate. (This preserves the checksum.)
    [self validate: xbSerialBaud value: [self baudToXBeeIndex: INITIL_BAUD] readOnly: NO err: &err];

    // Close our sockets.
    [self close];
#if DEBUG_ME
    printf("Close our sockets\n");
#endif
    
    // Release our lock.
    pthread_mutex_unlock(&mutex);
}

/*!
 * Called when the loader has completed loading the binary.
 *
 * This method is provided to insure the delegate is called from the main thread.
 */

- (void) loaderComplete {
    if ([delegate respondsToSelector: @selector(loaderComplete)])
        [delegate loaderComplete];
#if DEBUG_ME
    printf("loaderComplete\n");
#endif
}

/*!
 * This convenience method supports calling loaderFatalError from off of the main thread.
 *
 * @param err		The error that caused the failure.
 */

- (void) loaderFatalError: (NSError *) err {
    if ([delegate respondsToSelector: @selector(loaderFatalError:)])
        [delegate loaderFatalError: err];
#if DEBUG_ME
    printf("loaderFatalError\n");
#endif
}

/*!
 * Send UDP data packet to XBee's UART.  Data must be sized to exactly the number of bytes to transmit.
 *
 * @param data			The data to send.
 * @param useAppService	Pass YES to use the Application Service to verify the data packet was received (packet 
 *						acknowlegement) and retransmits if needed. Set UseAppService to NO to use Serial Service 
 *						instead (no verified receipt) and no automatic retransmission.
 * @param autoRetry		Set AutoRetry to NO to optionally prevent automatic retries (when UseAppService is active).
 *
 * @return				Returns YES if successful, NO if not.
 */

- (BOOL) sendUDP: (NSData *) data useAppService: (BOOL) useAppService autoRetry: (BOOL) autoRetry err: (NSError **) err {
	BOOL result = NO;
	if (data.length <= MAX_DATA_SIZE)
        // The data is small enough for a single packet. Send it.
		result = [self send: data useAppService: useAppService autoRetry: autoRetry err: err];
	else {
        // Break the data up into timed packets.
        int idx = 0;
        NSData *dataLeft = [NSData dataWithData: data];
        do {
            NSData *packet = nil;
            if (dataLeft.length <= MAX_DATA_SIZE) {
                result = YES;
                packet = dataLeft;
            } else {
                packet = [NSData dataWithBytes: dataLeft.bytes length: MAX_DATA_SIZE];
                dataLeft = [NSData dataWithBytes: ((UInt8 *) dataLeft.bytes) + MAX_DATA_SIZE length: dataLeft.length - MAX_DATA_SIZE];
            }
            
            if (idx > 0) {
                double time = MAX_DATA_SIZE*0.30*11/115200 - udpRoundTrip;
                if (time < 0)
                    time = 0;
                [NSThread sleepForTimeInterval: time];
            }
            if (![self send: packet useAppService: useAppService autoRetry: autoRetry err: err])
                break;
            
        } while (!result);
    }
    return result;
}

/*!
 * Send a block of data. This is a worker method for sendUDP.
 *
 * @param data			The data to send.
 * @param useAppService	Pass YES to use the Application Service to verify the data packet was received (packet
 *						acknowlegement) and retransmits if needed. Set UseAppService to NO to use Serial Service
 *						instead (no verified receipt) and no automatic retransmission.
 * @param autoRetry		Set AutoRetry to NO to prevent automatic retries (when UseAppService is active).
 *
 * @return				Returns YES if successful, NO if not.
 */

- (BOOL) send: (NSData *) data useAppService: (BOOL) useAppService autoRetry: (BOOL) autoRetry err: (NSError **) err {
    BOOL result = NO;
    if (useAppService) {
        // Prep and send data using Application Service. The weird sizing (subtracting 4 from the data length and
        // stuffing the data in the struct sarting at &frameID) is because prepareAppBuffer:tParamValueSize: can
        // handle either AT commands or data commands. This is a data command. The frame that is send to the XBee
        // is 4 bytes shorter for data commands.
        txPacketPtr packet = [self prepareAppBuffer: xbData tParamValueSize: (int) (data.length - 4) needReply: NO];
        memcpy(&packet->frameID, data.bytes, data.length);
        NSData *dataPacket = [[NSData alloc] initWithBytes: packet length: sizeof(txPacket) + data.length - 4];
        free(packet);
        [self transmitAppUDP: dataPacket expectMultiple: NO autoRetry: autoRetry needReply: NO err: err];
        result = *err == nil;
    } else {
        // Transmit it using Serial Service
        [self writeBytesToSerial: data tag: 2];
        result = YES;
    }
    return result;
}

/*!
 * Changes the loader progress. This method is designed to be called from off of the main thread, allowing the
 * progress value to be passed as an NSNumber. Call with performSelectorOnMainThread:withObject:waitUntilDone:.
 *
 * If the method is on the main thread, calling [delegate loaderProgress is equivalent].
 *
 * @param progress The progress as a vlaue from 0.0 to 1.0.
 */

- (void) loaderProgress: (NSNumber *) progress {
    if ([delegate respondsToSelector: @selector(loaderProgress:)])
        [delegate loaderProgress: [progress floatValue]];
}
    
/*!
 * Provides a mechanism for passing the loader state message to the delegate from the main thread. This method
 * must be called on the main thread.
 *
 * @param message		The message to pass to the delegate.
 */

- (void) setStateInDelegate: (NSString *) message {
    if ([delegate respondsToSelector: @selector(loaderState:)])
        [delegate loaderState: message];
}

/*!
 * Transmit (and retransmit if necessary) a packet, waiting for non-retransmit response or timeout.
 *
 * Returns response value (if any), returning any error in the err parameter.
 *
 * This method is the same as calling  with ignoreResponse: FALSE and customTimeout: 0.
 *
 * @param packet	The data to send.
 * @param length	The number of bytes in the packet.
 * @param err		The error. Undisturbed if there was no error.
 *
 * @return			The response code, which should be the next packet number to send.
 */

- (int) transmitPacket: (UInt8 *) packet length: (int) length err: (NSError **) err {
    return [self transmitPacket: packet length: length ignoreResponse: FALSE customTimeout: 0 err: err];
}

/*!
 * Transmit (and retransmit if necessary) a packet, waiting for non-retransmit response or timeout.
 *
 * Returns response value (if any), returning any error in the err parameter.
 *
 * @param packet			The data to send. This is modified by changing the second 4 byte word to a random packet ID.
 * @param length			The number of bytes in the packet.
 * @param ignoreResponse	Set IgnoreResponse true to transmit only; ignoring any possible response.
 * @param customTimeout		Set CustomTimeout only to wait for an extended maximum timeout (in seconds); 
 *							otherwise, TransmitPacket will wait based on a dynamicSerTimeout that is a 
 *							DYNAMIC_WAIT_FACTOR multiple of typical communication responses.
 * @param err				The error. Undisturbed if there was no error.
 *
 * @return					The response code, which should be the next packet number to send.
 */

- (int) transmitPacket: (UInt8 *) packet 
                length: (int) length 
        ignoreResponse: (BOOL) ignoreResponse 
         customTimeout: (float) customTimeout 
                   err: (NSError **) err 
{
    int retry = 3;
    NSData *rxBuff = nil;
    NSError *localErr = nil;
    
    BOOL acknowledged = NO;
    int rxPacketID = -1;
    do {
        // Generate random Transmission ID.
        if (!randInitialized) {
            randInitialized = YES;
            srand((unsigned int) time(nil));
        }
        UInt32 txTransmissionID = rand();
        UInt32 rxTransmissionID = txTransmissionID ^ 0xFFFFFFFF;
        [self patchLoaderLongValue: packet offset: 4 value: txTransmissionID];
        
        // (Re)transmit packet.
        txBuff = [NSData dataWithBytes: packet length: length];
#if PACKET_DUMP
        [self dump: txBuff title: nil];
#endif
        [self sendUDP: txBuff useAppService: NO autoRetry: NO err: &localErr];
        
        // Determine proper timeout; dynamic (typical) or extended custom (rare).
        float timeOut = [self dynamicSerTimeout] + customTimeout;
        
        // Wait for positive/negative acknowledgement of this specific  transmission, or timeout if none.  This loop 
        // throws out acknowledgements to previous transmissions, received late.
        do {
            acknowledged = !ignoreResponse && [self receiveUDP: &rxBuff timeout: timeOut];
            if (rxBuff != nil && rxBuff.length >= 8)
                rxTransmissionID = [self hostInitializedValue: (UInt8 *) rxBuff.bytes offset: 4];
        } while (!(!acknowledged || (txTransmissionID == rxTransmissionID)));
        
        // Amend Acknowledged flag with response's ACK/NAK status.
        UInt32 txID = [self hostInitializedValue: (UInt8 *) txBuff.bytes offset: 0];
        UInt32 rxID = txID ^ 0xFFFFFFFF;
        if (rxBuff != nil && rxBuff.length >= 8) {
            rxID = [self hostInitializedValue: (UInt8 *) rxBuff.bytes offset: 0];
        }
        acknowledged = acknowledged && txID != rxID;
        --retry;
        
        if (acknowledged)
            rxPacketID = [self hostInitializedValue: (UInt8 *) rxBuff.bytes offset: 0];
    } while (!(ignoreResponse || acknowledged || retry == 0));
    
    if (!(ignoreResponse || acknowledged)) {
        if (localErr != nil)
            *err = localErr;
        else
            *err = [self getError: 14];
    }
    
#if PACKET_DUMP
    printf("transmitPacket response: %d\n", ignoreResponse ? 0 : rxPacketID);
#endif
    return ignoreResponse ? 0 : rxPacketID;
}

/*!
 * Make sure a numeric attribute on the XBee is set to a specific value, changing it if needed.
 *
 * @param attribue		The attribute to check.
 * @param value			The desired value for the attribute. A 2 byte integer.
 * @param readOnly		YES if the attribute should be read and compared, but not set.
 * @param err			Set to an error value if there was an error readong or writing, or left unchanged if not.
 *
 * @return				YES for succes, or NO for an error. See err for the error code.
 */

- (BOOL) validate: (xbCommand) attribute value: (int) value readOnly: (BOOL) readOnly err: (NSError **) err {
    int setting = [self getItem: attribute err: err];
    BOOL result = setting == value;
    if (!result && !readOnly && !*err) {
        [self setAttribute: attribute value: value err: err];
        result = !*err;
    }
    return result;
}

/*!
 * Make sure an IP attribute on the XBee is set to a specific value, changing it if needed.
 *
 * IP Attributes are a bit wierd. WHile it can be set using wither a otted decimal or binary value, it always
 * returns a binary value. This method handles the difference.
 *
 * @param attribue		The attribute to check.
 * @param value			The desired value for the attribute. A 2 byte integer.
 * @param readOnly		YES if the attribute should be read and compared, but not set.
 * @param err			Set to an error value if there was an error readong or writing, or left unchanged if not.
 *
 * @return				YES for succes, or NO for an error. See err for the error code.
 */

- (BOOL) validate: (xbCommand) attribute string: (NSString *) value readOnly: (BOOL) readOnly err: (NSError **) err {
    int setting = [self getItem: attribute err: err];
    NSString *ipString = [NSString stringWithFormat: @"%d.%d.%d.%d", (setting >> 24) & 0x00FF, (setting >> 16) & 0x00FF, (setting >> 8) & 0x00FF, setting & 0x00FF];
    BOOL result = [ipString isEqualToString: value];
    if (!result && !readOnly && !*err) {
        [self setAttribute: attribute stringValue: value err: err];
        result = !*err;
    }
    return result;
}

#pragma mark - XBee I/O primitives

/*!
 * Write data to the XBee AT command UDP socket.
 *
 * @param data				The data to write.
 * @param tag				The tag for the write.
 */

- (void) writeBytesToBEE: (NSData *) data tag: (long) tag {
#if DEBUG_ME
    printf("writeBytesToBEE: ");
    for (int i = 0; i < data.length; ++i)
        printf(" %02X", ((UInt8 *) data.bytes)[i]);
    printf(" tag: %ld\n", tag);
#endif
    
    if (!udpSocket) {
        // Set the UDP ccommand socket.
        udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate: self delegateQueue: dispatch_get_main_queue()];
        
        // Bind to the port.
        NSError *error;
        [udpSocket bindToPort: [XBeeCommon udpPort] error: &error];
        if (error == nil)
            [udpSocket beginReceiving: &error];
    }
    
    [udpSocket sendData: data toHost: xBee.ipAddr port: [XBeeCommon udpPort] withTimeout: 0.1 tag: tag];
}

/*!
 * Write data to the XBee serial port.
 *
 * @param data				The data to write.
 * @param tag				The tag for the write.
 */

- (void) writeBytesToSerial: (NSData *) data tag: (long) tag {
#if DEBUG_ME
    printf("writeBytesToSerial port (%d): ", xBee.ipPort);
    for (int i = 0; i < data.length; ++i)
        printf(" %02X", ((UInt8 *) data.bytes)[i]);
    printf(" tag: %ld\n", tag);
#endif
    
    if (!udpSocket) {
        // Set the UDP ccommand socket.
        udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate: self delegateQueue: dispatch_get_main_queue()];
        
        // Bind to the port.
        NSError *error;
        [udpSocket bindToPort: [XBeeCommon udpPort] error: &error];
        if (error == nil)
            [udpSocket beginReceiving: &error];
    }
    
    [udpSocket sendData: data toHost: xBee.ipAddr port: xBee.ipPort withTimeout: 0.1 tag: tag];
}

/*!
 * Get a numeric value from the XBee.
 *
 * @param command		The attribute to read.
 * @param err			Set to an error code if there was a problem, or unchanged if not.
 */

- (int) getItem: (xbCommand) command err: (NSError **) err {
    // Prepare and send the command.
    int result = 0;
    txPacketPtr packet = [self prepareAppBuffer: command tParamValueSize: 0 needReply: YES];
    NSData *dataPacket = [[NSData alloc] initWithBytes: packet length: sizeof(txPacket)];
    free(packet);
    
    // Get the data.
    NSData *udpPacket = [self transmitAppUDP: dataPacket expectMultiple: NO autoRetry: YES needReply: YES err: err];
    
    // Fetch the result.
    if (!*err) {
        UInt8 *bytes = (UInt8 *) udpPacket.bytes;
        int length = (int) udpPacket.length;
        for (int i = 12; i < length; ++i)
            result = (result << 8) | bytes[i];
    }
    return result;
}

/*!
 * Get a string value from the XBee.
 *
 * @param command		The attribute to read.
 * @param err			Set to an error code if there was a problem, or unchanged if not.
 */

- (NSString *) getStringItem: (xbCommand) command err: (NSError **) err {
    // Prepare and send the command.
    txPacketPtr packet = [self prepareAppBuffer: command tParamValueSize: 0 needReply: YES];
    NSData *dataPacket = [[NSData alloc] initWithBytes: packet length: sizeof(txPacket)];
    free(packet);
    
    // Get the data.
    NSData *udpPacket = [self transmitAppUDP: dataPacket expectMultiple: NO autoRetry: YES needReply: YES err: err];
    
    // Fetch the result.
    NSString *result = @"";
    if (!*err) {
        UInt8 *bytes = (UInt8 *) udpPacket.bytes;
        int length = (int) udpPacket.length;
        for (int i = 12; i < length; ++i)
            if (bytes[i])
                result = [NSString stringWithFormat: @"%@%c", result, (char) bytes[i]];
            else 
                break;
    }
    return result;
}

/*!
 * Prepare the AT Command buffer.
 *
 * @param command			The command being sent.
 * @param tParamValueSize	The size of the tParamValue buffer. This is used to reserve space; the caller should fill it in.
 *
 * @return					The initialized command buffer. The caller is responsible for disposal with free.
 */

- (txPacketPtr) prepareAppBuffer: (xbCommand) command tParamValueSize: (int) tParamValueSize needReply: (BOOL) needReply {
    txPacketPtr packet = malloc(sizeof(txPacket) + tParamValueSize);
    packet->number1 = 0;
    packet->number2 = 0x4242;
    packet->packetID = 0;
    packet->encryptionPad = 0;
    packet->commandID = command == xbData ? 0 : 2;
    packet->commandOptions = needReply ? 2 : 0;
    if (command != xbData) {
        packet->frameID = 1;
        packet->configOptions = 2;
        memcpy(&packet->atCommand, atCmd[command], 2);
    }
    return packet;
}

/*!
 * Receive UDP data packet. Data will be resized to exactly fit the received byte stream.
 *
 * This always uses the Serial Service.
 *
 * @param tidBytes			(Output) If the receive is successful, the data is stored here; otherwise, this is unchanged.
 * @param timeout			The time in seconds to wait before giving up.
 *
 * @return		YES if successful, else NO.
 */

- (BOOL) receiveUDP: (NSData **) tidBytes timeout: (float) timeout {
    double startTime = CFAbsoluteTimeGetCurrent();
    NSData *udpAddress = nil;
    NSData *udpPacket = nil;
    double udpTime;
    
    while (udpPacket == nil && CFAbsoluteTimeGetCurrent() - startTime < timeout) {
        if ([udpStack pull: &udpPacket udpAddress: &udpAddress udpTime: &udpTime]) {
            // Make sure the packet came from the serial port. If not, it is junk.
            if (!(udpAddress != nil 
                  && udpAddress.length >= 4 
                  && ((UInt8 *) udpAddress.bytes)[2] == ((SERIAL_PORT >> 8) & 0x00FF) 
                  && ((UInt8 *) udpAddress.bytes)[3] == (SERIAL_PORT & 0x00FF)))
            {
                udpPacket = nil;
            }
        }
    }
    *tidBytes = udpPacket;
    return udpPacket != nil && udpPacket.length > 0;
}

/*!
 * Set one of the XBee attributes.
 *
 * @param attribute		The attribute to set.
 * @param value			The new value for the attribute.
 * @param err			Set to an error value if there was an error readong or writing, or left unchanged if not.
 */

- (void) setAttribute: (xbCommand) attribute value: (int) value err: (NSError **) err {
    // Prepare the message.
    txPacketPtr packet = [self prepareAppBuffer: attribute tParamValueSize: 1 needReply: YES];
    packet->tParamValue[0] = value;
    NSData *dataPacket = [[NSData alloc] initWithBytes: packet length: sizeof(txPacket) + 1];
    free(packet);
    
    // Send the command.
    [self transmitAppUDP: dataPacket expectMultiple: NO autoRetry: YES needReply: YES err: err];
}

/*!
 * Set one of the XBee attributes.
 *
 * @param attribute		The attribute to set.
 * @param value			The new value for the attribute.
 * @param err			Set to an error value if there was an error readong or writing, or left unchanged if not.
 */

- (void) setAttribute: (xbCommand) attribute stringValue: (NSString *) stringValue err: (NSError **) err {
    // Prepare the message.
    txPacketPtr packet = [self prepareAppBuffer: attribute tParamValueSize: (int) stringValue.length needReply: YES];
    const char *str = [stringValue UTF8String];
    for (int i = 0; i < strlen(str); ++i)
        packet->tParamValue[i] = str[i];
    NSData *dataPacket = [[NSData alloc] initWithBytes: packet length: sizeof(txPacket) + strlen(str)];
    free(packet);
    
    // Send the command.
    [self transmitAppUDP: dataPacket expectMultiple: NO autoRetry: YES needReply: YES err: err];
}

/*!
 * Transmit UDP packet and wait for a response.
 *
 * Returned data is in udpPacket. The address from which the data was received is in udpAddress.
 *
 * @param data				The data to transmit.
 * @param expectMultiple	YES if multiple responses possible, such as when a packet is being broadcast to multiple XBee modules.
 * @param autoRetry			If YES, the packet is automatically retransmitted if expected response(s) not received.
 * @param needReply			Do we need a reply from the XBee device?
 * @param err				Set to an error if one occurred, or unchanged if not.
 *
 * @return					The returned data packer, or nil if there wasn't one.
 */

- (NSData *) transmitAppUDP: (NSData *) data
             expectMultiple: (BOOL) expectMultiple
                  autoRetry: (BOOL) autoRetry
                  needReply: (BOOL) needReply
                        err: (NSError **) err
{
    NSData *udpAddress = nil;
    NSData *udpPacket = nil;
    double udpTime;
    
    int txCount = autoRetry ? 3 : 1;
    BOOL packetReceived = NO;
    do {
        double time = CFAbsoluteTimeGetCurrent();
        [self writeBytesToBEE: data tag: 1];
        if (needReply) {
            while (![self validPacket] && (CFAbsoluteTimeGetCurrent() - time < UDP_TIMEOUT))
                [NSThread sleepForTimeInterval: 0.001];
            if ([self validPacket]) {
                [udpStack pull: &udpPacket udpAddress: &udpAddress udpTime: &udpTime];
                udpRoundTrip = udpTime - time;
                udpMaxRoundTrip = udpMaxRoundTrip > udpRoundTrip ? udpMaxRoundTrip : udpRoundTrip;
                packetReceived = YES;
            } else
                --txCount;
        } else
            packetReceived = YES;
    } while (!packetReceived && txCount > 0);
    if (needReply) {
        if (!packetReceived)
            *err = [self getError: 1];
        else if (udpPacket == nil)
            [self getError: 2];
        else if (((UInt8 *) udpPacket.bytes)[11] != 0)
            [self getError: 3 
    localizedFailureReason: [NSString stringWithFormat: @"A UDP command was sent to the XBee, which responded with error code %d", ((UInt8 *) udpPacket.bytes)[11]]];
    }
    
    return udpPacket;
}

/*!
 * Check to see if the top packet is a valid response to an XBee configuration command or data command response. If not,
 * discard it and try again until there are no more packets or the top packet is valid.
 *
 * @return			YES if the top (remaining) packet is a valid configuratoin or data command response, else NO.
 */

- (BOOL) validPacket {
    NSData *udpAddress = nil;
    NSData *udpPacket = nil;
    double udpTime;
    
    BOOL valid = NO;
    for (;;) {
	    if ([udpStack peek: &udpPacket udpAddress: &udpAddress udpTime: &udpTime]) {
            if (udpPacket != nil && udpPacket.length > 4) {
                UInt8 *bytes = (UInt8 *) udpPacket.bytes;
                if (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0x42 && bytes[3] == 0x42) {
                    valid = YES;
                    break;
                }
            }
            
            // This is not the droid we are looking for...
            [udpStack pull: &udpPacket udpAddress: &udpAddress udpTime: &udpTime];
        } else
            break;
    }
    return valid;
}

#pragma mark - XBee Device Scanning

/*!
 * Get the name for a device.
 *
 * Do not call this method on the main thread.
 *
 * @param theXBee	Information about the XBee device.
 */

- (NSString *) getDeviceName: (TXBee *) theXBee {
    // Make sure we have a UDP socket.
    if (!udpSocket) {
	    udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate: self delegateQueue: dispatch_get_main_queue()];
        
        // Bind to the port.
        NSError *error;
        [udpSocket bindToPort: [XBeeCommon udpPort] error: &error];
        
        // Start listening for data on the bound port.
        [udpSocket beginReceiving: &error];
    }
    
    // Save the XBee deivice.
    self.xBee = theXBee;
    
    // Get the name of the device.
    NSError *err;
    NSString *result = [self getStringItem: xbNodeID err: &err];
    if (err)
        result = @"";
    return result;
}

/*!
 * Scans an IP subnet for XBee devices.
 *
 * Do not call this method on the main thread.
 *
 * @param subnet			The subnet to scan. The last octet must be 255; e.g. @"10.0.1.255"
 * @param commandPort		The UDP command port, generally 0x0BEE.
 * @param serialPort		The UDP serial port, generally 0x2616.
 */

- (void) scan: (NSString *) subnet commandPort: (int) commandPort serialPort: (int) serialPort {
#if DEBUG_ME
    printf("Scanning for XBee devices on %s:%d at %f\n", [subnet cStringUsingEncoding: NSUTF8StringEncoding], commandPort, CFAbsoluteTimeGetCurrent());
#endif
    
    // Create an empty device list.
    self.deviceList = [[NSMutableArray alloc] init];
    
    // Make sure we have a UDP socket.
    NSError *error;
    if (!udpSocket) {
	    udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate: self delegateQueue: dispatch_get_main_queue()];
    
        // Bind to the port. This can only be done once, so multiple calls to scan will report an error here, but it does not matter.
        [udpSocket bindToPort: commandPort error: &error];
        
        // Start listening for data on the bound port.
        [udpSocket beginReceiving: &error];
    }
    
    // Enable broadcasting.
    [udpSocket enableBroadcast: YES error: &error];
    
    // Send the scan request to any listening XBee WiFi device.
    txPacketPtr packet = [self prepareAppBuffer: xbIPAddr tParamValueSize: 0 needReply: YES];
    NSData *dataPacket = [[NSData alloc] initWithBytes: packet length: sizeof(txPacket)];
    free(packet);
#if PACKET_DUMP
    [self dump: dataPacket title: @"\nSending scan command."];
#endif
    [udpSocket sendData: dataPacket toHost: subnet port: commandPort withTimeout: 0.1 tag: 3];
    
    // Wait for replies for 1 second.
    double time = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - time < 1.0) {
        NSData *udpAddress = nil;
        NSData *udpPacket = nil;
        double udpTime;
        
        if ([udpStack pull: &udpPacket udpAddress: &udpAddress udpTime: &udpTime]) {
#if PACKET_DUMP
            [self dump: udpPacket title: @"\nScan response."];
#endif
            if (udpPacket) {
                UInt8 *bytes = (UInt8 *) udpPacket.bytes;
                if (udpPacket.length == 16 && bytes[9] == 'M' && bytes[10] == 'Y' && bytes[11] == 0) {
                    NSString *ipAddr = [NSString stringWithFormat: @"%d.%d.%d.%d", bytes[12], bytes[13], bytes[14], bytes[15]];
                    TXBee *xBeeDevice = [[TXBee alloc] init];
                    xBeeDevice.ipPort = serialPort;
                    xBeeDevice.cfgChecksum = VALUE_UNKNOWN;
                    xBeeDevice.ipAddr = ipAddr;
                    xBeeDevice.name = @"";
                    [deviceList addObject: xBeeDevice];
                }
            }
        }
    }
    
    // Get the name of each device found.
    TXBee *oldXBee = xBee;
    for (TXBee *xBeeDevice in deviceList)
        xBeeDevice.name = [self getDeviceName: xBeeDevice];
    self.xBee = oldXBee;
    
    // Set the devices.
    if ([delegate respondsToSelector: @selector(loaderDevices:)]) {
        [delegate loaderDevices: deviceList];
    }
}

#pragma mark - GCDAsyncUdpSocketDelegate

/*!
 * Called when the datagram with the given tag has been sent.
 *
 * @param sock		The object handling the UDP socket.
 * @param tag		An optional tag that was sent with the original write.
 */

- (void) udpSocket: (GCDAsyncUdpSocket *) sock didSendDataWithTag: (long) tag {
#if DEBUG_ME
    printf("udpSocket:didSendDataWithTag:%ld\n", tag);
#endif
}

/*!
 * Called when the socket has received the requested datagram.
 *
 * @param sock				The object handling the UDP socket.
 * @param data				The data received.
 * @param address			The address from which the data was received.
 * @param filterContext		The filter.
 */

- (void) udpSocket: (GCDAsyncUdpSocket *) sock
    didReceiveData: (NSData *) data
       fromAddress: (NSData *) address
 withFilterContext: (id) filterContext
{
#if DEBUG_ME
    printf("didReceiveData at %f from: ", CFAbsoluteTimeGetCurrent());
//    for (int i = 0; i < address.length; ++i)
//        printf("%02X", ((UInt8 *) address.bytes)[i]);
//    printf(": ");
    for (int i = 0; i < address.length; ++i)
        printf(" %02X", ((UInt8 *) address.bytes)[i]);
    printf(": ");
    for (int i = 0; i < data.length; ++i)
        printf(" %02X", ((UInt8 *) data.bytes)[i]);
    printf("\n");
#endif
    // If this arrived from the serial port, save the packet data.
    [udpStack push: data udpAddress: address udpTime: CFAbsoluteTimeGetCurrent()];
}

/*!
 * Called if an error occurs while trying to send a datagram. This could be due to a timeout, or something
 * more serious such as the data being too large to fit in a single packet.
 *
 * @param sock		The object handling the UDP socket.
 * @param tag		An optional tag that was sent with the original write.
 * @param error		The error.
 */

- (void) udpSocket: (GCDAsyncUdpSocket *)sock didNotSendDataWithTag: (long) tag dueToError: (NSError *) error {
#if DEBUG_ME
    printf("didNotSendDataWithTag: %ld dueToError: %s\n", tag, [error.localizedDescription cStringUsingEncoding: NSUTF8StringEncoding]);
#endif
}

@end
