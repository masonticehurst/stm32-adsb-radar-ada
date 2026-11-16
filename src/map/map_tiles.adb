package body Map_Tiles is

   --------------
   -- Is_Valid --
   --------------

   function Is_Valid (H : File_Header) return Boolean is
      Expected_Record : Unsigned_32;
   begin
      if H.Magic /= Magic or else H.Version /= Format_Version
        or else H.Tile_Size /= Tile_Pixels or else H.Data_Offset /= Header_Size
        or else H.Zoom > Max_Zoom
      then
         return False;
      end if;

      case H.Format is
         when Format_RGB565 =>
            Expected_Record := RGB565_Record_Size;
         when Format_L8 =>
            Expected_Record := L8_Record_Size;
         when others =>
            return False;
      end case;

      if H.Record_Size /= Expected_Record then
         return False;
      end if;

      --  The grid must be non-empty and lie inside the 2**Zoom x 2**Zoom
      --  world. Each test is written so that it cannot overflow.
      return
        H.Width in 1 .. Max_Grid_Side and then H.Height in 1 .. Max_Grid_Side
        and then H.X_Min <= Shift_Left (1, Natural (H.Zoom)) - H.Width
        and then H.Y_Min <= Shift_Left (1, Natural (H.Zoom)) - H.Height;
   end Is_Valid;

   -----------------
   -- Tile_Offset --
   -----------------

   function Tile_Offset
     (H : File_Header; X, Y : Unsigned_32) return Unsigned_64
   is
      Index : constant Unsigned_64 :=
        Unsigned_64 (Y - H.Y_Min) * Unsigned_64 (H.Width) +
        Unsigned_64 (X - H.X_Min);
   begin
      return Unsigned_64 (H.Data_Offset) + Index * Unsigned_64 (H.Record_Size);
   end Tile_Offset;

end Map_Tiles;
