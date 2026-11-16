with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;
with Ada.Real_Time;                     use Ada.Real_Time;
with BMP_Fonts;                         use BMP_Fonts;
with Bitmapped_Drawing;
with HAL.Bitmap;                        use HAL.Bitmap;

with Controls;
with GPS;
with Ownship;
with Screen;
with Text_Format; use Text_Format;
with Track_Popup;
with Traffic;

package body Overlay is

   Ring_Color : constant Bitmap_Color :=
     (Alpha => 255, Red => 0, Green => 200, Blue => 255);
   Ownship_Color : constant Bitmap_Color := White;
   Text_Color    : constant Bitmap_Color := White;
   Error_Color   : constant Bitmap_Color :=
     (Alpha => 255, Red => 255, Green => 90, Blue => 90);
   Text_Back : constant Bitmap_Color :=
     (Alpha => 170, Red => 0, Green => 0, Blue => 0);
   Traffic_Color : constant Bitmap_Color :=
     (Alpha => 255, Red => 80, Green => 255, Blue => 120);
   Selected_Color : constant Bitmap_Color := White;

   --  A tap within this many pixels of a traffic symbol selects it
   Pick_Radius : constant := 22;

   --  Vertical rate beyond which the label shows a climb/descent arrow
   Trend_Fpm : constant := 500;

   Small : constant BMP_Font := Font8x8;
   Large : constant BMP_Font := Font12x12;

   ------------------
   -- Screen_Point --
   ------------------

   --  Screen position of a geographic position, rounded the same way as
   --  the map tiles so symbols sit on the right map pixel
   procedure Screen_Point
     (P    : Geo.Position; View_Px : Geo.World_Pixel; Zoom : Map_View.Map_Zoom;
      X, Y : out Integer)
   is
      W : constant Geo.World_Pixel := Geo.To_World_Pixel (P, Zoom);
   begin
      X :=
        Screen.Centre_X + Integer (Long_Float'Floor (W.X)) -
        Integer (Long_Float'Floor (View_Px.X));
      Y :=
        Screen.Centre_Y + Integer (Long_Float'Floor (W.Y)) -
        Integer (Long_Float'Floor (View_Px.Y));
   end Screen_Point;

   ------------------
   -- Text helpers --
   ------------------

   function Text_Width (Msg : String; Font : BMP_Font) return Natural is
     (Msg'Length * Char_Width (Font));

   procedure Put
     (Buffer : Any_Bitmap_Buffer; X, Y : Natural; Msg : String;
      Font   : BMP_Font; Color : Bitmap_Color := Text_Color)
   is
   begin
      Bitmapped_Drawing.Draw_String
        (Buffer.all, Start => (X, Y), Msg => Msg, Font => Font,
         Foreground        => Color, Background => Text_Back);
   end Put;

   procedure Put_Centred
     (Buffer : Any_Bitmap_Buffer; Y : Natural; Msg : String; Font : BMP_Font;
      Color  : Bitmap_Color := Text_Color)
   is
      W : constant Natural :=
        Natural'Min (Text_Width (Msg, Font), Screen.Width);
   begin
      Put (Buffer, (Screen.Width - W) / 2, Y, Msg, Font, Color);
   end Put_Centred;

   -----------------------
   -- Clipped primitives --
   -----------------------

   --  HAL.Bitmap points are Natural, so shapes that may lie partly off
   --  screen (own ship and rings after panning) are drawn with these.

   function On_Screen (X, Y : Integer) return Boolean is
     (X in 0 .. Screen.Width - 1 and then Y in 0 .. Screen.Height - 1);

   procedure Plot (Buffer : Any_Bitmap_Buffer; X, Y : Integer) is
   begin
      if On_Screen (X, Y) then
         Buffer.Set_Pixel ((X, Y));
      end if;
   end Plot;

   --  Midpoint circle, current source color
   procedure Clipped_Circle
     (Buffer : Any_Bitmap_Buffer; CX, CY : Integer; Radius : Natural)
   is
      X   : Integer := Radius;
      Y   : Integer := 0;
      Err : Integer := 1 - Radius;
   begin
      while X >= Y loop
         Plot (Buffer, CX + X, CY + Y);
         Plot (Buffer, CX - X, CY + Y);
         Plot (Buffer, CX + X, CY - Y);
         Plot (Buffer, CX - X, CY - Y);
         Plot (Buffer, CX + Y, CY + X);
         Plot (Buffer, CX - Y, CY + X);
         Plot (Buffer, CX + Y, CY - X);
         Plot (Buffer, CX - Y, CY - X);

         Y := Y + 1;
         if Err < 0 then
            Err := Err + 2 * Y + 1;
         else
            X   := X - 1;
            Err := Err + 2 * (Y - X) + 1;
         end if;
      end loop;
   end Clipped_Circle;

   --  Filled rectangle given by its corners, clipped to the screen
   procedure Clipped_Box (Buffer : Any_Bitmap_Buffer; X0, Y0, X1, Y1 : Integer)
   is
      L : constant Integer := Integer'Max (0, X0);
      T : constant Integer := Integer'Max (0, Y0);
      R : constant Integer := Integer'Min (Screen.Width - 1, X1);
      B : constant Integer := Integer'Min (Screen.Height - 1, Y1);
   begin
      if L <= R and then T <= B then
         Buffer.Fill_Rect (((L, T), R - L + 1, B - T + 1));
      end if;
   end Clipped_Box;

   --  Bresenham line between two screen points, current source color
   procedure Clipped_Line
     (Buffer : Any_Bitmap_Buffer; X0, Y0, X1, Y1 : Integer)
   is
      DX  : constant Integer := abs (X1 - X0);
      DY  : constant Integer := -abs (Y1 - Y0);
      SX  : constant Integer := (if X0 < X1 then 1 else -1);
      SY  : constant Integer := (if Y0 < Y1 then 1 else -1);
      X   : Integer          := X0;
      Y   : Integer          := Y0;
      Err : Integer          := DX + DY;
      E2  : Integer;
   begin
      loop
         Plot (Buffer, X, Y);
         exit when X = X1 and then Y = Y1;
         E2 := 2 * Err;
         if E2 >= DY then
            Err := Err + DY;
            X   := X + SX;
         end if;
         if E2 <= DX then
            Err := Err + DX;
            Y   := Y + SY;
         end if;
      end loop;
   end Clipped_Line;

   --  Text drawn only if it fits on screen entirely
   procedure Put_If_Fits
     (Buffer : Any_Bitmap_Buffer; X, Y : Integer; Msg : String;
      Color  : Bitmap_Color)
   is
   begin
      if X >= 0 and then Y >= 0
        and then X + Text_Width (Msg, Small) <= Screen.Width
        and then Y + Char_Height (Small) <= Screen.Height
      then
         Put (Buffer, X, Y, Msg, Small, Color);
      end if;
   end Put_If_Fits;

   -------------------
   -- Draw_Aircraft --
   -------------------

   --  One traffic symbol at screen point (X, Y): a chevron pointing along
   --  its track (a diamond if no direction yet), labelled with callsign
   --  (or ICAO address) and altitude in hundreds of feet, e.g. "074^"
   procedure Draw_Aircraft
     (Buffer : Any_Bitmap_Buffer; X, Y : Integer; A : Traffic.Aircraft)
   is
      --  Chevron outline, nose up, before rotation
      type Point is record
         X, Y : Float;
      end record;
      Shape : constant array (1 .. 4) of Point :=
        ((0.0, -9.0), (6.0, 7.0), (0.0, 3.0), (-6.0, 7.0));

      PX, PY : array (1 .. 4) of Integer;

      Name : constant String :=
        (if A.Callsign_Len > 0 then A.Callsign (1 .. A.Callsign_Len)
         else Hex6 (A.ICAO));

      function Altitude_Text return String is
         Hundreds : constant Integer :=
           Integer'Max (0, Integer'Min (999, A.Altitude_Ft / 100));
         Digits3 : constant String := Img (1_000 + Hundreds);
         Trend   : constant String :=
           (if not A.Has_VRate then "" elsif A.VRate_Fpm > Trend_Fpm then "^"
            elsif A.VRate_Fpm < -Trend_Fpm then "v" else "");
      begin
         if not A.Airborne then
            return "GND";
         elsif not A.Has_Altitude then
            return "---";
         else
            --  1000 + hundreds, minus its leading "1": zero-padded 3 digits
            return Digits3 (Digits3'First + 1 .. Digits3'Last) & Trend;
         end if;
      end Altitude_Text;
   begin
      Buffer.Set_Source (Traffic_Color);

      if A.Has_Direction then
         --  Rotate clockwise by the track angle (screen Y points down)
         declare
            S : constant Float := Sin (Float (A.Direction_Deg), 360.0);
            C : constant Float := Cos (Float (A.Direction_Deg), 360.0);
         begin
            for I in Shape'Range loop
               PX (I) := X + Integer (Shape (I).X * C - Shape (I).Y * S);
               PY (I) := Y + Integer (Shape (I).X * S + Shape (I).Y * C);
            end loop;
         end;

         for I in Shape'Range loop
            declare
               J : constant Positive := (if I = Shape'Last then 1 else I + 1);
            begin
               Clipped_Line (Buffer, PX (I), PY (I), PX (J), PY (J));
               Clipped_Line (Buffer, PX (I) + 1, PY (I), PX (J) + 1, PY (J));
            end;
         end loop;
      else
         --  Diamond
         Clipped_Line (Buffer, X, Y - 6, X + 6, Y);
         Clipped_Line (Buffer, X + 6, Y, X, Y + 6);
         Clipped_Line (Buffer, X, Y + 6, X - 6, Y);
         Clipped_Line (Buffer, X - 6, Y, X, Y - 6);
      end if;

      Put_If_Fits (Buffer, X + 10, Y - 10, Name, Traffic_Color);
      Put_If_Fits (Buffer, X + 10, Y - 1, Altitude_Text, Traffic_Color);
   end Draw_Aircraft;

   ------------------
   -- Draw_Traffic --
   ------------------

   --  Every aircraft with a recent position, placed like own ship relative
   --  to the view centre; the selected one gets a ring around it
   procedure Draw_Traffic
     (Buffer : Any_Bitmap_Buffer; View_Px : Geo.World_Pixel;
      Zoom   : Map_View.Map_Zoom; Selected : Unsigned_32)
   is
      Now    : constant Time := Clock;
      Margin : constant      := 60;  --  symbol + label beyond the edge
      X, Y   : Integer;
   begin
      for S in Traffic.Slot loop
         declare
            A : constant Traffic.Aircraft := Traffic.Get (S);
         begin
            if Traffic.Position_Fresh (A, Now) then
               Screen_Point (A.Position, View_Px, Zoom, X, Y);

               if X in -Margin .. Screen.Width + Margin
                 and then Y in -Margin .. Screen.Height + Margin
               then
                  if A.ICAO = Selected then
                     Buffer.Set_Source (Selected_Color);
                     Clipped_Circle (Buffer, X, Y, 14);
                     Clipped_Circle (Buffer, X, Y, 15);
                  end if;

                  Draw_Aircraft (Buffer, X, Y, A);
               end if;
            end if;
         end;
      end loop;
   end Draw_Traffic;

   -------------------
   -- Pick_Aircraft --
   -------------------

   function Pick_Aircraft
     (X, Y : Integer; View_Centre : Geo.Position; Zoom : Map_View.Map_Zoom)
      return Unsigned_32
   is
      View_Px : constant Geo.World_Pixel :=
        Geo.To_World_Pixel (View_Centre, Zoom);
      Now     : constant Time := Clock;
      Best    : Unsigned_32   := Traffic.No_Aircraft;
      Best_D2 : Integer       := Pick_Radius * Pick_Radius + 1;
      AX, AY  : Integer;
   begin
      for S in Traffic.Slot loop
         declare
            A : constant Traffic.Aircraft := Traffic.Get (S);
         begin
            if Traffic.Position_Fresh (A, Now) then
               Screen_Point (A.Position, View_Px, Zoom, AX, AY);

               --  Only nearby symbols; the nearest one wins
               if abs (AX - X) <= Pick_Radius
                 and then abs (AY - Y) <= Pick_Radius
                 and then (AX - X)**2 + (AY - Y)**2 < Best_D2
               then
                  Best    := A.ICAO;
                  Best_D2 := (AX - X)**2 + (AY - Y)**2;
               end if;
            end if;
         end;
      end loop;

      return Best;
   end Pick_Aircraft;

   -------------------
   -- Draw_Ownship --
   -------------------

   --  Simple aircraft symbol, nose up (north-up display, no heading yet),
   --  centred on screen point (X, Y). White with a live GPS fix; red and
   --  crossed out when the position is not current (no fix yet, so the
   --  built-in position, or the fix was lost, so the last one).
   procedure Draw_Ownship (Buffer : Any_Bitmap_Buffer; X, Y : Integer) is
      use type Ownship.Source;
      Live : constant Boolean := Ownship.Status = Ownship.Live_Fix;
      Arm  : constant         := 14;  --  half the size of the X

      --  The symbol's three boxes, grown by G pixels on every side
      procedure Plane (G : Natural) is
      begin
         Clipped_Box (Buffer, X - 1 - G, Y - 9 - G, X + G, Y + 8 + G);
         Clipped_Box (Buffer, X - 9 - G, Y - 2 - G, X + 9 + G, Y - 1 + G);
         Clipped_Box (Buffer, X - 4 - G, Y + 6 - G, X + 4 + G, Y + 7 + G);
      end Plane;
   begin
      if Live then
         Buffer.Set_Source (Ownship_Color);
         Plane (0);
         return;
      end if;

      --  Red X behind, then the red plane on a dark outline so its shape
      --  still reads through the X
      Buffer.Set_Source (Error_Color);
      for D in 0 .. 1 loop
         Clipped_Line (Buffer, X - Arm + D, Y - Arm, X + Arm + D, Y + Arm);
         Clipped_Line (Buffer, X + Arm + D, Y - Arm, X - Arm + D, Y + Arm);
      end loop;
      Buffer.Set_Source (Black);
      Plane (1);
      Buffer.Set_Source (Error_Color);
      Plane (0);
   end Draw_Ownship;

   ----------------------
   -- Draw_Range_Rings --
   ----------------------

   --  Rings at the full and half display range around screen point (X, Y)
   procedure Draw_Range_Rings
     (Buffer : Any_Bitmap_Buffer; X, Y : Integer; Lat : Geo.Latitude;
      Zoom   : Map_View.Map_Zoom)
   is
      Range_NM  : constant Positive   := Map_View.Range_NM (Zoom);
      Px_Per_NM : constant Long_Float := Geo.Pixels_Per_NM (Lat, Zoom);
      Outer     : constant Natural    :=
        Natural
          (Long_Float'Min
             (Long_Float (Range_NM) * Px_Per_NM,
              Long_Float (Screen.Centre_Y - 1)));
      Inner : constant Natural := Outer / 2;

      --  Label just inside the top of a ring, if that spot is on screen
      procedure Label (Radius : Natural; Text : String) is
         LX : constant Integer := X + 4;
         LY : constant Integer := Y - Radius + 3;
      begin
         if LX >= 0 and then LY >= 0
           and then LX + Text_Width (Text, Small) <= Screen.Width
           and then LY + Char_Height (Small) <= Screen.Height
         then
            Put (Buffer, LX, LY, Text, Small, Ring_Color);
         end if;
      end Label;
   begin
      Buffer.Set_Source (Ring_Color);
      Clipped_Circle (Buffer, X, Y, Outer);
      Clipped_Circle (Buffer, X, Y, Inner);

      Label (Outer, Img (Range_NM));
      Label (Inner, (if Range_NM > 2 then Img (Range_NM / 2) else "1"));
   end Draw_Range_Rings;

   -----------------
   -- Draw_Notice --
   -----------------

   --  Message in a rounded box, centred above the position line
   procedure Draw_Notice
     (Buffer : Any_Bitmap_Buffer; Msg : String; Is_Error : Boolean)
   is
      Fill : constant Bitmap_Color :=
        (Alpha => 230, Red => 16, Green => 20, Blue => 28);
      Edge : constant Bitmap_Color :=
        (if Is_Error then Error_Color else Traffic_Color);

      Pad    : constant         := 8;
      Height : constant         := 12 + 2 * Pad;
      Width  : constant Natural :=
        Natural'Min (Text_Width (Msg, Large) + 2 * Pad, Screen.Width);
      Left : constant Natural := (Screen.Width - Width) / 2;
      Top  : constant         := Screen.Height - 16 - Height;
   begin
      Buffer.Set_Source (Fill);
      Buffer.Fill_Rounded_Rect (((Left, Top), Width, Height), 6);
      Buffer.Set_Source (Edge);
      Buffer.Draw_Rounded_Rect
        (((Left, Top), Width, Height), 6, Thickness => 2);
      Bitmapped_Drawing.Draw_String
        (Buffer.all, Start => (Left + Pad, Top + Pad), Msg => Msg,
         Font              => Large, Foreground => Edge, Background => Fill);
   end Draw_Notice;

   ----------
   -- Draw --
   ----------

   procedure Draw
     (Own_Position : Geo.Position; View_Centre : Geo.Position;
      Zoom : Map_View.Map_Zoom; Following : Boolean; Selected : Unsigned_32;
      Followed     : Unsigned_32; Notice : String := "";
      Notice_Error : Boolean := False)
   is
      Buffer : constant Any_Bitmap_Buffer := Screen.Overlay_Layer;

      View_Px : constant Geo.World_Pixel :=
        Geo.To_World_Pixel (View_Centre, Zoom);
      Own_X, Own_Y : Integer;

      Pos_Txt : constant String :=
        Degrees (Own_Position.Lat, 'N', 'S', 2) & " " &
        Degrees (Own_Position.Lon, 'E', 'W', 3) &
        (case Ownship.Status is when Ownship.Built_In => " NO GPS",
           when Ownship.Live_Fix                      =>
             " GPS " & Img (GPS.Latest.Satellites) & " SAT",
           when Ownship.Last_Fix => " GPS LOST");
      Map_Msg  : constant String := Map_View.Status_Text (Zoom);
      Bottom_Y : constant        := Screen.Height - 9;
   begin
      Screen_Point (Own_Position, View_Px, Zoom, Own_X, Own_Y);

      Buffer.Set_Source (Transparent);
      Buffer.Fill;

      Draw_Range_Rings (Buffer, Own_X, Own_Y, Own_Position.Lat, Zoom);
      Draw_Traffic (Buffer, View_Px, Zoom, Selected);
      Draw_Ownship (Buffer, Own_X, Own_Y);

      if Map_Msg'Length > 0 then
         Put_Centred (Buffer, 20, Map_Msg, Large, Error_Color);
      end if;

      --  Bottom: own position
      Put (Buffer, 2, Bottom_Y, Pos_Txt, Small);

      Controls.Draw
        (Buffer, Can_Zoom_In => Zoom < Map_View.Map_Zoom'Last,
         Can_Zoom_Out        => Zoom > Map_View.Map_Zoom'First,
         Off_Ownship         => not Following);

      --  Details panel on top of the map symbols
      if Selected /= Traffic.No_Aircraft then
         Track_Popup.Draw
           (Buffer, Selected, Own_Position, Following => Followed = Selected);
      end if;

      --  Notice last, on top of everything else
      if Notice'Length > 0 then
         Draw_Notice (Buffer, Notice, Notice_Error);
      end if;
   end Draw;

   -----------------
   -- Draw_Splash --
   -----------------

   procedure Draw_Splash (Message : String) is
      Buffer : constant Any_Bitmap_Buffer := Screen.Overlay_Layer;
   begin
      Buffer.Set_Source (Transparent);
      Buffer.Fill;
      Put_Centred (Buffer, 100, "ADS-B RADAR", Font16x24);
      Put_Centred (Buffer, 140, Message, Large);
   end Draw_Splash;

end Overlay;
