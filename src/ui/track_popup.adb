with Ada.Real_Time; use Ada.Real_Time;
with BMP_Fonts;     use BMP_Fonts;
with Bitmapped_Drawing;
with HAL.Bitmap;    use HAL.Bitmap;

with CSBee;
with Text_Format; use Text_Format;
with Traffic;

package body Track_Popup is

   --  Panel geometry (screen pixels)
   Left   : constant := 4;
   Top    : constant := 32;
   Width  : constant := 180;
   Height : constant := 182;
   Radius : constant := 6;

   Close_Size : constant := 22;
   Close_X    : constant := Left + Width - Close_Size - 4;
   Close_Y    : constant := Top + 4;
   Touch_Pad  : constant := 6;

   Text_X     : constant := Left + 8;
   Value_X    : constant := Text_X + 7 * 8;  --  after "LABEL  "
   First_Row  : constant := Top + 26;
   Row_Height : constant := 11;
   Row_Count  : constant := 11;

   --  Centre-and-follow button, under the last row
   Follow_X      : constant := Left + 8;
   Follow_Y      : constant := First_Row + Row_Count * Row_Height + 3;
   Follow_Width  : constant := Width - 16;
   Follow_Height : constant := 24;

   Panel_Fill : constant Bitmap_Color :=
     (Alpha => 230, Red => 16, Green => 20, Blue => 28);
   Border      : constant Bitmap_Color := White;
   Title_Color : constant Bitmap_Color :=
     (Alpha => 255, Red => 80, Green => 255, Blue => 120);
   Label_Color : constant Bitmap_Color :=
     (Alpha => 255, Red => 150, Green => 160, Blue => 175);
   Value_Color  : constant Bitmap_Color := White;
   Follow_Color : constant Bitmap_Color :=  --  as the centre button
     (Alpha => 255, Red => 0, Green => 200, Blue => 255);
   Disabled_Color : constant Bitmap_Color :=
     (Alpha => 255, Red => 100, Green => 100, Blue => 100);

   --------------
   -- Contains --
   --------------

   function Contains (X, Y : Integer) return Boolean is
     (X in Left .. Left + Width - 1 and then Y in Top .. Top + Height - 1);

   ---------------
   -- Close_Hit --
   ---------------

   function Close_Hit (X, Y : Integer) return Boolean is
     (X in Close_X - Touch_Pad .. Close_X + Close_Size + Touch_Pad
      and then Y in Close_Y - Touch_Pad .. Close_Y + Close_Size + Touch_Pad);

   ----------------
   -- Follow_Hit --
   ----------------

   --  No extra touch area: the button already fills the panel's width,
   --  and the area just above it is the SEEN row
   function Follow_Hit (X, Y : Integer) return Boolean is
     (X in Follow_X .. Follow_X + Follow_Width - 1
      and then Y in Follow_Y .. Follow_Y + Follow_Height - 1);

   ----------
   -- Draw --
   ----------

   procedure Draw
     (Buffer       : HAL.Bitmap.Any_Bitmap_Buffer; ICAO : Unsigned_32;
      Own_Position : Geo.Position; Following : Boolean)
   is
      S   : constant Natural := Traffic.Find (ICAO);
      Row : Natural          := 0;

      procedure Put
        (X, Y : Natural; Text : String; Font : BMP_Font; Color : Bitmap_Color)
      is
      begin
         Bitmapped_Drawing.Draw_String
           (Buffer.all, Start => (X, Y), Msg => Text, Font => Font,
            Foreground        => Color, Background => Panel_Fill);
      end Put;

      --  One "LABEL  value" row
      procedure Line (Label, Value : String) is
         Y : constant Natural := First_Row + Row * Row_Height;
      begin
         Put (Text_X, Y, Label, Font8x8, Label_Color);
         Put (Value_X, Y, Value, Font8x8, Value_Color);
         Row := Row + 1;
      end Line;
   begin
      if S = 0 then
         return;
      end if;

      declare
         A   : constant Traffic.Aircraft := Traffic.Get (S);
         Now : constant Time             := Clock;

         Name : constant String :=
           (if A.Callsign_Len > 0 then A.Callsign (1 .. A.Callsign_Len)
            else Hex6 (A.ICAO));

         Seen_S : constant Integer :=
           Integer (To_Duration (Now - A.Last_Heard));
      begin
         --  Panel and border
         Buffer.Set_Source (Panel_Fill);
         Buffer.Fill_Rounded_Rect (((Left, Top), Width, Height), Radius);
         Buffer.Set_Source (Border);
         Buffer.Draw_Rounded_Rect
           (((Left, Top), Width, Height), Radius, Thickness => 1);

         --  Close button: box with an X
         Buffer.Draw_Rect (((Close_X, Close_Y), Close_Size, Close_Size));
         Buffer.Draw_Line
           ((Close_X + 5, Close_Y + 5),
            (Close_X + Close_Size - 6, Close_Y + Close_Size - 6),
            Thickness => 2);
         Buffer.Draw_Line
           ((Close_X + Close_Size - 6, Close_Y + 5),
            (Close_X + 5, Close_Y + Close_Size - 6), Thickness => 2);

         Put (Text_X, Top + 7, Name, Font12x12, Title_Color);

         Line ("ICAO", Hex6 (A.ICAO));
         Line
           ("BAND",
            (case A.Source is when CSBee.Mode_S => "1090 ES",
               when CSBee.UAT                   => "978 UAT"));

         Line
           ("ALT",
            (if not A.Airborne then "GROUND"
             elsif A.Has_Altitude then Grouped (A.Altitude_Ft) & " FT"
             else "---"));
         Line
           ("V/S",
            (if A.Has_VRate then Grouped (A.VRate_Fpm) & " FPM" else "---"));
         Line
           ("TRK", (if A.Has_Direction then Img (A.Direction_Deg) else "---"));
         Line
           ("GS", (if A.Has_Speed then Img (A.Speed_Kt) & " KT" else "---"));

         if A.Has_Position then
            Line ("LAT", Degrees (A.Position.Lat, 'N', 'S', 2));
            Line ("LON", Degrees (A.Position.Lon, 'E', 'W', 3));
            Line
              ("DIST",
               Tenths (Geo.Distance_NM (Own_Position, A.Position)) & " NM");
            Line
              ("BRG",
               Img
                 (Integer (Geo.Bearing_Deg (Own_Position, A.Position)) mod
                  360));
         else
            Line ("LAT", "---");
            Line ("LON", "---");
            Line ("DIST", "---");
            Line ("BRG", "---");
         end if;

         Line ("SEEN", Img (Integer'Max (0, Seen_S)) & " S AGO");

         --  Centre-and-follow button: filled while following, grey while
         --  there is no current position to follow
         declare
            Area : constant Rect :=
              ((Follow_X, Follow_Y), Follow_Width, Follow_Height);
            Can_Follow : constant Boolean := Traffic.Position_Fresh (A, Now);
            Label      : constant String  :=
              (if Following then "FOLLOWING"
               elsif Can_Follow then "CENTER & FOLLOW" else "NO POSITION");
            Color : constant Bitmap_Color :=
              (if Following or else Can_Follow then Follow_Color
               else Disabled_Color);
            Back : constant Bitmap_Color :=
              (if Following then Follow_Color else Panel_Fill);
         begin
            Buffer.Set_Source (Back);
            Buffer.Fill_Rounded_Rect (Area, 4);
            Buffer.Set_Source (Color);
            Buffer.Draw_Rounded_Rect (Area, 4, Thickness => 2);
            Bitmapped_Drawing.Draw_String
              (Buffer.all,
               Start =>
                 (Follow_X + (Follow_Width - Label'Length * 8) / 2,
                  Follow_Y + (Follow_Height - 8) / 2),
               Msg        => Label, Font => Font8x8,
               Foreground => (if Following then Black else Color),
               Background => Back);
         end;
      end;
   end Draw;

end Track_Popup;
