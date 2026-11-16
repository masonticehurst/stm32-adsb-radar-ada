with File_IO;    use File_IO;
with HAL.Bitmap; use HAL.Bitmap;
with Interfaces; use Interfaces;
with STM32.DMA2D_Bitmap;
with STM32.SDRAM;

with Debug_Log;
with Map_Tiles; use Map_Tiles;
with SD_Card;
with Screen;

package body Map_View is

   Background : constant Bitmap_Color :=
     (Alpha => 255, Red => 10, Green => 12, Blue => 16);

   Current_Status : Map_Status := Not_Started;

   Headers : array (Map_Zoom) of File_Header;
   Valid   : array (Map_Zoom) of Boolean := (others => False);

   --  Tile cache in SDRAM (24 x 128 KB = 3 MB), reserved once by
   --  Initialize. A screen needs at most 3 x 3 tiles, so a short pan or a
   --  zoom in and back out is served from the cache. When full, the least
   --  recently used tile is replaced.
   Cache_Size : constant := 24;

   type Cache_Slot is record
      In_Use   : Boolean                                := False;
      Zoom     : Map_Zoom                               := Map_Zoom'First;
      X, Y     : Natural                                := 0;
      Last_Use : Unsigned_32                            := 0;
      Buffer   : STM32.DMA2D_Bitmap.DMA2D_Bitmap_Buffer :=
        STM32.DMA2D_Bitmap.Null_Buffer;
   end record;

   subtype Slot_Index is Positive range 1 .. Cache_Size;

   Cache      : array (Slot_Index) of Cache_Slot;
   Use_Count  : Unsigned_32 := 0;
   Have_Cache : Boolean     := False;

   --  The zoom file is opened only when a tile is not in the cache
   type File_State is (Not_Opened, Opened, Open_Failed);

   function Img (N : Integer) return String;
   --  'Image without the leading space

   function Img (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return (if S (S'First) = ' ' then S (S'First + 1 .. S'Last) else S);
   end Img;

   ---------------
   -- File_Name --
   ---------------

   function Short_Name (Zoom : Map_Zoom) return String is
     ("Z" & Character'Val (Character'Pos ('0') + Zoom / 10) &
      Character'Val (Character'Pos ('0') + Zoom mod 10) & ".BIN");

   function File_Name (Zoom : Map_Zoom) return String is
     ("/" & Mount_Point & "/" & Short_Name (Zoom));

   ---------------
   -- Floor_Div --
   ---------------

   --  Division rounding toward minus infinity (Ada's "/" truncates)
   function Floor_Div (A, B : Integer) return Integer is
     (if A >= 0 then A / B else -((-A + B - 1) / B));

   -----------------
   -- Load_Header --
   -----------------

   procedure Load_Header (Zoom : Map_Zoom) is
      File   : File_Descriptor;
      Result : Status_Code;
      Count  : File_Size;
      Size   : File_Size;
   begin
      Valid (Zoom) := False;

      Result := Open (File, File_Name (Zoom), Read_Only);
      if Result /= OK then
         Debug_Log.Put_Line
           (Short_Name (Zoom) & ": not found (" & Result'Image & ")");
         return;
      end if;

      Size  := File_IO.Size (File);
      Count := Read (File, Headers (Zoom)'Address, Header_Size);
      Close (File);

      if Count /= Header_Size then
         Debug_Log.Put_Line (Short_Name (Zoom) & ": short header");
         return;
      end if;

      declare
         H : File_Header renames Headers (Zoom);
      begin
         if not Is_Valid (H) or else Natural (H.Zoom) /= Zoom then
            Debug_Log.Put_Line (Short_Name (Zoom) & ": bad header");
            return;
         end if;

         if H.Format /= Format_RGB565 then
            Debug_Log.Put_Line
              (Short_Name (Zoom) & ": only RGB565 tiles" &
               " are supported so far");
            return;
         end if;

         --  The file must hold every record the header promises
         if Unsigned_64 (Size) <
           Unsigned_64 (H.Data_Offset) +
             Unsigned_64 (H.Width) * Unsigned_64 (H.Height) *
               Unsigned_64 (H.Record_Size)
         then
            Debug_Log.Put_Line (Short_Name (Zoom) & ": file truncated");
            return;
         end if;

         Valid (Zoom) := True;
         Debug_Log.Put_Line
           (Short_Name (Zoom) & ": ok, x " & Img (Integer (H.X_Min)) & " y " &
            Img (Integer (H.Y_Min)) & " grid " & Img (Integer (H.Width)) &
            "x" & Img (Integer (H.Height)));
      end;
   end Load_Header;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
      Result : Status_Code;
   begin
      if not Have_Cache then
         for Slot of Cache loop
            Slot.Buffer :=
              (Addr =>
                 STM32.SDRAM.Reserve
                   (Amount => RGB565_Record_Size, Align => 32),
               Actual_Width      => Tile_Pixels, Actual_Height => Tile_Pixels,
               Actual_Color_Mode => RGB_565, Currently_Swapped => False,
               Native_Source     => 0);
         end loop;
         Have_Cache := True;
      end if;

      SD_Card.Initialize;

      case SD_Card.Status is
         when SD_Card.Ready =>
            null;
         when SD_Card.No_Card =>
            Current_Status := No_Card;
            Debug_Log.Put_Line ("SD: no card");
            return;
         when SD_Card.Card_Error | SD_Card.Not_Initialized =>
            Current_Status := Card_Error;
            Debug_Log.Put_Line ("SD: card did not initialise");
            return;
      end case;

      Result := Mount_Drive (Mount_Point, SD_Card.Device'Access);
      if Result /= OK then
         Current_Status := No_Filesystem;
         Debug_Log.Put_Line ("SD: mount failed (" & Result'Image & ")");
         return;
      end if;

      Current_Status := Mounted;
      Debug_Log.Put_Line ("SD: mounted");

      for Zoom in Map_Zoom loop
         Load_Header (Zoom);
      end loop;

   exception
      when others =>
         Current_Status := Card_Error;
         Debug_Log.Put_Line ("SD: unexpected error during start-up");
   end Initialize;

   ------------
   -- Status --
   ------------

   function Status return Map_Status is (Current_Status);

   --------------------
   -- Zoom_Available --
   --------------------

   function Zoom_Available (Zoom : Map_Zoom) return Boolean is
     (Current_Status = Mounted and then Valid (Zoom));

   -----------------
   -- Status_Text --
   -----------------

   function Status_Text (Zoom : Map_Zoom) return String is
   begin
      case Current_Status is
         when Not_Started =>
            return "MAP NOT STARTED";
         when No_Card =>
            return "NO SD CARD";
         when Card_Error =>
            return "SD CARD ERROR";
         when No_Filesystem =>
            return "SD CARD NOT FAT32";
         when Mounted =>
            return
              (if Valid (Zoom) then ""
               else Short_Name (Zoom) & " MISSING OR INVALID");
      end case;
   end Status_Text;

   -----------------------
   -- Clamp_To_Coverage --
   -----------------------

   function Clamp_To_Coverage
     (Centre : Geo.Position; Zoom : Map_Zoom) return Geo.Position
   is
   begin
      if not Zoom_Available (Zoom) then
         return Centre;
      end if;

      declare
         H    : File_Header renames Headers (Zoom);
         P    : Geo.World_Pixel     := Geo.To_World_Pixel (Centre, Zoom);
         Px   : constant Long_Float := Long_Float (Tile_Pixels);
         X_Lo : constant Long_Float := Long_Float (H.X_Min) * Px;
         Y_Lo : constant Long_Float := Long_Float (H.Y_Min) * Px;
         X_Hi : constant Long_Float := X_Lo + Long_Float (H.Width) * Px - 1.0;
         Y_Hi : constant Long_Float := Y_Lo + Long_Float (H.Height) * Px - 1.0;
      begin
         if P.X in X_Lo .. X_Hi and then P.Y in Y_Lo .. Y_Hi then
            return Centre;  --  Already inside: avoid round-trip drift
         end if;

         P.X := Long_Float'Max (X_Lo, Long_Float'Min (X_Hi, P.X));
         P.Y := Long_Float'Max (Y_Lo, Long_Float'Min (Y_Hi, P.Y));
         return Geo.From_World_Pixel (P, Zoom);
      end;
   end Clamp_To_Coverage;

   ----------------
   -- Find_Cached --
   ----------------

   --  Cache slot holding tile (X, Y) at Zoom, or 0
   function Find_Cached (Zoom : Map_Zoom; X, Y : Natural) return Natural is
   begin
      for I in Cache'Range loop
         if Cache (I).In_Use and then Cache (I).Zoom = Zoom
           and then Cache (I).X = X and then Cache (I).Y = Y
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Cached;

   ----------------
   -- Free_Slot --
   ----------------

   --  An unused slot, otherwise the least recently used one
   function Free_Slot return Slot_Index is
      Oldest : Slot_Index := Cache'First;
   begin
      for I in Cache'Range loop
         if not Cache (I).In_Use then
            return I;
         elsif Cache (I).Last_Use < Cache (Oldest).Last_Use then
            Oldest := I;
         end if;
      end loop;

      return Oldest;
   end Free_Slot;

   ---------------
   -- Draw_Tile --
   ---------------

   --  Copy the visible part of tile (Tile_X, Tile_Y) to the map layer,
   --  reading it from the card first if it is not in the cache. Left and
   --  Top are the world pixel at the screen's top-left corner.
   procedure Draw_Tile
     (File : in out File_Descriptor; State : in out File_State;
      Zoom :        Map_Zoom; Tile_X, Tile_Y : Integer; Left, Top : Integer)
   is
      H : File_Header renames Headers (Zoom);

      --  Tile's top-left corner on screen; may be off screen to the left
      --  or above
      Screen_X : constant Integer := Tile_X * Tile_Pixels - Left;
      Screen_Y : constant Integer := Tile_Y * Tile_Pixels - Top;

      Src_X : constant Integer := Integer'Max (0, -Screen_X);
      Src_Y : constant Integer := Integer'Max (0, -Screen_Y);
      Dst_X : constant Integer := Integer'Max (0, Screen_X);
      Dst_Y : constant Integer := Integer'Max (0, Screen_Y);
      W     : constant Integer :=
        Integer'Min (Tile_Pixels, Screen.Width - Screen_X) - Src_X;
      Ht : constant Integer :=
        Integer'Min (Tile_Pixels, Screen.Height - Screen_Y) - Src_Y;

      Offset : File_Size;
      Count  : File_Size;
      Slot   : Natural;

      --  This tile's part of the screen in plain background, for tiles
      --  outside the file's coverage or that could not be read
      procedure Fill_Background is
      begin
         Screen.Map_Layer.Set_Source (Background);
         Screen.Map_Layer.Fill_Rect (((Dst_X, Dst_Y), W, Ht));
      end Fill_Background;
   begin
      if W <= 0 or else Ht <= 0 then
         return;  --  Not on screen at all
      end if;

      if Tile_X < 0 or else Tile_Y < 0
        or else not In_Grid (H, Unsigned_32 (Tile_X), Unsigned_32 (Tile_Y))
      then
         Fill_Background;
         return;
      end if;

      Slot := Find_Cached (Zoom, Tile_X, Tile_Y);

      if Slot = 0 then
         --  Not cached: read it from the card into a free slot
         if State = Not_Opened then
            if Open (File, File_Name (Zoom), Read_Only) = OK then
               State := Opened;
            else
               State := Open_Failed;
               Debug_Log.Put_Line (Short_Name (Zoom) & ": open failed");
            end if;
         end if;

         if State /= Opened then
            Fill_Background;
            return;
         end if;

         Slot                := Free_Slot;
         Cache (Slot).In_Use := False;

         Offset :=
           File_Size
             (Tile_Offset (H, Unsigned_32 (Tile_X), Unsigned_32 (Tile_Y)));

         if Seek (File, From_Start, Offset) /= OK then
            Fill_Background;
            return;
         end if;

         Count := Read (File, Cache (Slot).Buffer.Addr, RGB565_Record_Size);
         if Count /= RGB565_Record_Size then
            Debug_Log.Put_Line
              ("tile read failed at x" & Img (Tile_X) & " y" & Img (Tile_Y));
            Fill_Background;
            return;
         end if;

         Cache (Slot).In_Use := True;
         Cache (Slot).Zoom   := Zoom;
         Cache (Slot).X      := Tile_X;
         Cache (Slot).Y      := Tile_Y;
      end if;

      Use_Count             := Use_Count + 1;
      Cache (Slot).Last_Use := Use_Count;

      Copy_Rect
        (Src_Buffer => Cache (Slot).Buffer, Src_Pt => (Src_X, Src_Y),
         Dst_Buffer => Screen.Map_Layer.all, Dst_Pt => (Dst_X, Dst_Y),
         Width      => W, Height => Ht, Synchronous => True);
   end Draw_Tile;

   ----------
   -- Draw --
   ----------

   procedure Draw (Centre : Geo.Position; Zoom : Map_Zoom) is
      Buffer : constant Any_Bitmap_Buffer := Screen.Map_Layer;
      File   : File_Descriptor;
      State  : File_State                 := Not_Opened;
   begin
      --  No full-screen clear: the tile loop below covers every pixel,
      --  filling background wherever there is no tile. That saves one
      --  full-screen DMA2D write per frame.
      if not Zoom_Available (Zoom) or else not Have_Cache then
         Buffer.Set_Source (Background);
         Buffer.Fill;
         return;
      end if;

      declare
         Centre_Px : constant Geo.World_Pixel :=
           Geo.To_World_Pixel (Centre, Zoom);
         --  World pixel shown at the screen's top-left corner
         Left : constant Integer :=
           Integer (Long_Float'Floor (Centre_Px.X)) - Screen.Centre_X;
         Top : constant Integer :=
           Integer (Long_Float'Floor (Centre_Px.Y)) - Screen.Centre_Y;
      begin
         --  Row-major order matches the file layout, so the FAT driver
         --  only ever seeks forward
         for Tile_Y in
           Floor_Div (Top, Tile_Pixels) ..
             Floor_Div (Top + Screen.Height - 1, Tile_Pixels)
         loop
            for Tile_X in
              Floor_Div (Left, Tile_Pixels) ..
                Floor_Div (Left + Screen.Width - 1, Tile_Pixels)
            loop
               Draw_Tile (File, State, Zoom, Tile_X, Tile_Y, Left, Top);
            end loop;
         end loop;

         if State = Opened then
            Close (File);
         end if;
      end;

   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Debug_Log.Put_Line ("map draw failed");

         --  Don't leave a half-drawn frame from two redraws ago
         Buffer.Set_Source (Background);
         Buffer.Fill;
   end Draw;

end Map_View;
