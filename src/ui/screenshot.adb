with Ada.Real_Time; use Ada.Real_Time;
with Interfaces;    use Interfaces;
with System;
with System.Storage_Elements;

with HAL;

with File_IO; use File_IO;
with STM32_SVD.LTDC;

with Debug_Log;
with Map_View;

package body Screenshot is

   use STM32_SVD.LTDC;
   use type HAL.UInt3;
   use type HAL.UInt13;
   use type Map_View.Map_Status;

   Width  : constant := 480;
   Height : constant := 272;

   --  Both layers are 2 bytes per pixel. BMP rows are 3 bytes per pixel,
   --  a multiple of 4 here, so they need no padding.
   Pitch        : constant := Width * 2;
   Row_Bytes    : constant := Width * 3;
   Header_Bytes : constant := 54;          --  file header + BITMAPINFOHEADER
   Image_Bytes  : constant := Row_Bytes * Height;

   --  LTDC pixel format codes (LxPFCR)
   Format_RGB565   : constant := 2;
   Format_ARGB4444 : constant := 4;

   Max_Shots : constant := 9_999;

   --  adl_middleware's FAT File_IO.Write writes whole blocks straight to
   --  the card assuming the file position is on a 512-byte boundary, so a
   --  write that starts mid-block lands in the wrong place. Everything
   --  goes through this buffer and is written a whole chunk at a time;
   --  only the last, shorter write may end mid-block.
   Chunk_Size : constant := 8_192;
   Chunk      : array (0 .. Chunk_Size - 1) of Unsigned_8 with
      Alignment => 4;
   Used : Natural := 0;

   Next_Number : Positive := 1;  --  first number that might be free

   Last_Name : String (1 .. 12) := (others => ' ');  --  "SHOTnnnn.BMP"

   Write_Failed : exception;

   ---------------
   -- File_Name --
   ---------------

   function File_Name (N : Natural) return String is
      Digits_Of : String (1 .. 4);
      V         : Natural := N;
   begin
      for I in reverse Digits_Of'Range loop
         Digits_Of (I) := Character'Val (Character'Pos ('0') + V mod 10);
         V             := V / 10;
      end loop;
      return "/" & Map_View.Mount_Point & "/SHOT" & Digits_Of & ".BMP";
   end File_Name;

   ----------
   -- Save --
   ----------

   procedure Save (Saved : out Boolean) is
      Start : constant Time := Clock;
      File  : File_Descriptor;
      Probe : File_Descriptor;
      Name  : Natural       := 0;

      procedure Flush_Chunk is
      begin
         if Used > 0 then
            if Write (File, Chunk'Address, File_Size (Used)) /=
              File_Size (Used)
            then
               raise Write_Failed;
            end if;
            Used := 0;
         end if;
      end Flush_Chunk;

      procedure Put (B : Unsigned_8) is
      begin
         Chunk (Used) := B;
         Used         := Used + 1;
         if Used = Chunk_Size then
            Flush_Chunk;
         end if;
      end Put;

      procedure Put_16 (V : Unsigned_16) is
      begin
         Put (Unsigned_8 (V and 16#FF#));
         Put (Unsigned_8 (Shift_Right (V, 8)));
      end Put_16;

      procedure Put_32 (V : Unsigned_32) is
      begin
         for I in 0 .. 3 loop
            Put (Unsigned_8 (Shift_Right (V, 8 * I) and 16#FF#));
         end loop;
      end Put_32;

      procedure Fail (Why : String) is
      begin
         Debug_Log.Put_Line ("screenshot: " & Why);
      end Fail;

   begin
      Saved := False;
      Used  := 0;

      if Map_View.Status /= Map_View.Mounted then
         Fail ("no card");
         return;
      end if;

      --  Both layers on, full screen, in the formats Screen sets up
      if not LTDC_Periph.L1CR.LEN or else not LTDC_Periph.L2CR.LEN
        or else LTDC_Periph.L1PFCR.PF /= Format_RGB565
        or else LTDC_Periph.L2PFCR.PF /= Format_ARGB4444
        or else LTDC_Periph.L1CFBLR.CFBP /= Pitch
        or else LTDC_Periph.L2CFBLR.CFBP /= Pitch
      then
         Fail ("unexpected display layer setup");
         return;
      end if;

      --  First unused name (each try is a directory lookup)
      for N in Next_Number .. Max_Shots loop
         case Open (Probe, File_Name (N), Read_Only) is
            when OK =>
               Close (Probe);
            when No_Such_File =>
               Name := N;
               exit;
            when others =>
               Fail ("cannot read the card");
               return;
         end case;
      end loop;

      if Name = 0 then
         Fail ("all" & Max_Shots'Image & " names used");
         return;
      end if;

      if Open (File, File_Name (Name), Write_Only) /= OK then
         Fail ("cannot create " & File_Name (Name));
         return;
      end if;

      --  BMP header: file header, then BITMAPINFOHEADER. A positive
      --  height means rows are stored bottom row first.
      Put (Character'Pos ('B'));
      Put (Character'Pos ('M'));
      Put_32 (Header_Bytes + Image_Bytes);  --  file size
      Put_32 (0);                           --  reserved
      Put_32 (Header_Bytes);                --  offset of the pixels
      Put_32 (40);                          --  BITMAPINFOHEADER size
      Put_32 (Width);
      Put_32 (Height);
      Put_16 (1);                           --  planes
      Put_16 (24);                          --  bits per pixel
      Put_32 (0);                           --  no compression
      Put_32 (Image_Bytes);
      Put_32 (2_835);                       --  72 dpi, in pixels/metre
      Put_32 (2_835);
      Put_32 (0);                           --  no palette
      Put_32 (0);

      declare
         use System.Storage_Elements;

         type Frame is array (0 .. Width * Height - 1) of Unsigned_16;

         --  The buffers on screen now (not the ones being drawn into)
         Map_Px : constant Frame with
            Import,
            Address => To_Address (Integer_Address (LTDC_Periph.L1CFBAR));
         Over_Px : constant Frame with
            Import,
            Address => To_Address (Integer_Address (LTDC_Periph.L2CFBAR));

            --  Widen 5 or 6 bits to 8 by repeating the top bits, as the LTDC
            --  does
         function Five (V : Unsigned_16) return Unsigned_16 is
           (Shift_Left (V, 3) or Shift_Right (V, 2));
         function Six (V : Unsigned_16) return Unsigned_16 is
           (Shift_Left (V, 2) or Shift_Right (V, 4));

         --  Overlay channel C (0 .. 15, widened to 0 .. 255 by * 17) over
         --  map channel M, with alpha A (0 .. 15)
         function Blend (C, M, A : Unsigned_16) return Unsigned_8 is
           (Unsigned_8 ((C * 17 * A + M * (15 - A) + 7) / 15));

         M, O, A : Unsigned_16;
      begin
         for Y in reverse 0 .. Height - 1 loop
            for X in 0 .. Width - 1 loop
               M := Map_Px (Y * Width + X);
               O := Over_Px (Y * Width + X);
               A := Shift_Right (O, 12);

               --  BMP pixels are blue, green, red
               Put (Blend (O and 16#F#, Five (M and 16#1F#), A));
               Put
                 (Blend
                    (Shift_Right (O, 4) and 16#F#,
                     Six (Shift_Right (M, 5) and 16#3F#), A));
               Put
                 (Blend
                    (Shift_Right (O, 8) and 16#F#, Five (Shift_Right (M, 11)),
                     A));
            end loop;
         end loop;
      end;

      Flush_Chunk;

      if Flush (File) /= OK then
         raise Write_Failed;
      end if;
      Close (File);

      Next_Number := Name + 1;
      declare
         Path : constant String := File_Name (Name);
      begin
         Last_Name := Path (Path'Last - 11 .. Path'Last);
      end;
      Saved := True;
      Debug_Log.Put_Line
        ("screenshot: saved " & File_Name (Name) & " in" &
         Integer'Image (Integer (To_Duration (Clock - Start) * 1_000)) &
         " ms");

   exception
      when Write_Failed =>
         if Is_Open (File) then
            Close (File);
         end if;
         Fail ("write failed (card full or card error)");

      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         if Is_Open (Probe) then
            Close (Probe);
         end if;
         Fail ("failed");
   end Save;

   ---------------
   -- Last_File --
   ---------------

   function Last_File return String is (Last_Name);

end Screenshot;
