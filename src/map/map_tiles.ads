--  Layout of the map tile files Z08.BIN .. Z12.BIN written by
--  Tiles/stm32_tiles.py. Keep this file and stm32_tiles.py in step.
--
--  File layout (little-endian):
--     bytes 0 .. 2047   File_Header (4 SD sectors)
--     bytes 2048 ..     fixed-size tile records in row-major order, each on
--                       a 512-byte sector boundary:
--        offset = 2048 + ((Y - Y_Min) * Width + (X - X_Min)) * Record_Size
--
--  Every byte of the header is a named field (hence Reserved_2 and
--  Reserved_3): stream 'Read ignores gaps in a representation clause, and
--  this way 'Read and a raw-sector overlay see the same bytes.

with Interfaces; use Interfaces;
with System;

package Map_Tiles is

   Header_Size    : constant        := 2_048;
   Sector_Size    : constant        := 512;
   Tile_Pixels    : constant        := 256;
   Format_Version : constant        := 1;
   Magic          : constant String := "ADSBMAP1";

   --  Pixel formats (File_Header.Format)
   Format_RGB565 : constant := 0;
   Format_L8     : constant := 1;

   RGB565_Record_Size : constant := Tile_Pixels * Tile_Pixels * 2;
   L8_Record_Size     : constant := Tile_Pixels * Tile_Pixels;

   --  Highest zoom level and largest grid accepted by Is_Valid
   Max_Zoom      : constant := 22;
   Max_Grid_Side : constant := 4_096;

   --  0xFFRRGGBB entries, used by the L8 format only. Entry 0 is black.
   type Palette_Array is array (Unsigned_8) of Unsigned_32 with
      Component_Size => 32;

   type Byte_Array is array (Natural range <>) of Unsigned_8 with
      Component_Size => 8;

   subtype Reserved_2_Array is Byte_Array (44 .. 63);
   subtype Reserved_3_Array is Byte_Array (1_088 .. 2_047);

   type File_Header is record
      Magic         : String (1 .. 8);
      Version       : Unsigned_16;
      Zoom          : Unsigned_8;
      Format        : Unsigned_8;
      Tile_Size     : Unsigned_16;
      Reserved_1    : Unsigned_16;
      X_Min         : Unsigned_32;
      Y_Min         : Unsigned_32;
      Width         : Unsigned_32;
      Height        : Unsigned_32;
      Record_Size   : Unsigned_32;
      Data_Offset   : Unsigned_32;
      Tiles_Present : Unsigned_32;
      Reserved_2    : Reserved_2_Array;
      Palette       : Palette_Array;
      Reserved_3    : Reserved_3_Array;
   end record;

   for File_Header use record
      Magic         at     0 range 0 ..    63;
      Version       at     8 range 0 ..    15;
      Zoom          at    10 range 0 ..     7;
      Format        at    11 range 0 ..     7;
      Tile_Size     at    12 range 0 ..    15;
      Reserved_1    at    14 range 0 ..    15;
      X_Min         at    16 range 0 ..    31;
      Y_Min         at    20 range 0 ..    31;
      Width         at    24 range 0 ..    31;
      Height        at    28 range 0 ..    31;
      Record_Size   at    32 range 0 ..    31;
      Data_Offset   at    36 range 0 ..    31;
      Tiles_Present at    40 range 0 ..    31;
      Reserved_2    at    44 range 0 ..   159;
      Palette       at    64 range 0 .. 8_191;
      Reserved_3    at 1_088 range 0 .. 7_679;
   end record;

   for File_Header'Size use Header_Size * 8;
   for File_Header'Bit_Order use System.Low_Order_First;

   --  True when every field the board relies on is consistent. Check this
   --  before trusting any other field of a header read from the card.
   function Is_Valid (H : File_Header) return Boolean;

   --  True when tile (X, Y) is inside the file's grid
   function In_Grid (H : File_Header; X, Y : Unsigned_32) return Boolean is
     (X >= H.X_Min and then X - H.X_Min < H.Width and then Y >= H.Y_Min
      and then Y - H.Y_Min < H.Height) with
      Pre => Is_Valid (H);

      --  Byte offset of tile (X, Y) from the start of the file
   function Tile_Offset
     (H : File_Header; X, Y : Unsigned_32) return Unsigned_64 with
      Pre => Is_Valid (H) and then In_Grid (H, X, Y);

      --  Sector of tile (X, Y), counted from the start of the file
   function Tile_Sector
     (H : File_Header; X, Y : Unsigned_32) return Unsigned_64 is
     (Tile_Offset (H, X, Y) / Sector_Size) with
      Pre => Is_Valid (H) and then In_Grid (H, X, Y);

      --  Palette entry in the LTDC_LxCLUTWR format (index in bits 31..24)
   function LTDC_CLUT_Word
     (H : File_Header; Index : Unsigned_8) return Unsigned_32 is
     (Shift_Left (Unsigned_32 (Index), 24) or
      (H.Palette (Index) and 16#00FF_FFFF#));

end Map_Tiles;
