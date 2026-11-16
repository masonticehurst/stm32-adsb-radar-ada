--  ADS-B Radar & Moving Map: main program.
--
--  Current state: moving map centred on Ownship from the GT-U7 GPS on
--  USART6 (a built-in position until the first fix), with live ADS-B
--  traffic from the ADSBee on UART7, controlled from the touch screen:
--     "+" / "-" buttons   zoom in / out (2, 4, 8, 16, 32 NM range)
--     drag on the map     pan; the map stops following Ownship
--     centre button       recentre on Ownship and follow it again
--     tap an aircraft     details panel; its CENTER & FOLLOW button keeps
--                         the map on that aircraft until tapped again,
--                         a drag, or the centre button
--  The blue USER button saves a screenshot to the SD card (SHOTnnnn.BMP).
--  The green LED (LD1) blinks twice a second as a heartbeat.

with Ada.Exceptions;
with Ada.Real_Time; use Ada.Real_Time;
with STM32.Board;   use STM32.Board;
with STM32_SVD.DBG;

with Adsb_UART;
with Adsbee;
with Controls;   use Controls;
with Debug_Log;
with Geo;
with GPS;
with GPS_UART;
with Map_View;   use Map_View;
with Overlay;
with Ownship;
with Screen;
with Screenshot;
with Touch_Input;
with Track_Popup;
with Traffic;
with Interfaces; use Interfaces;
with Text_Format;

procedure Adsb_Radar is

   use type Geo.Position;
   use type Ownship.Source;

   Tick_Period      : constant Time_Span := Milliseconds (16);
   Heartbeat_Period : constant Time_Span := Milliseconds (500);
   Report_Period    : constant Time_Span := Seconds (1);

   --  At most one full redraw per this period (25 per second). Every
   --  redraw keeps DMA2D busy on SDRAM, which the LCD also reads from, so
   --  this limits that traffic while dragging. Pan movements keep adding
   --  up in between, so the map still tracks the finger.
   Min_Redraw_Interval : constant Time_Span := Milliseconds (40);

   --  New traffic reports redraw the screen at most this often. The
   --  receiver reports each aircraft about once a second, so this keeps
   --  symbols current without redrawing for every single line.
   Traffic_Redraw_Interval : constant Time_Span := Milliseconds (500);
   Next_Traffic_Redraw     : Time;

   --  A touch on the map only becomes a drag after moving this far, so a
   --  plain tap doesn't nudge the map off Ownship
   Drag_Threshold : constant := 6;

   --  Samples in a row without a touch before the finger counts as lifted;
   --  the panel sometimes drops a sample mid-drag
   Release_Samples : constant := 2;

   Next_Tick      : Time;
   Next_Heartbeat : Time;
   Next_Report    : Time;
   Next_Redraw    : Time;  --  earliest time the next redraw may start

   Report_Count : Natural := 0;  --  ADS-B log reports so far

   Start_Zoom  : constant Map_Zoom := 10;  --  8 NM
   Zoom        : Map_Zoom          := Start_Zoom;
   View_Centre : Geo.Position      := Ownship.Position;
   Following   : Boolean           := True;
   Redraw      : Boolean           := True;

   --  Ownship as last drawn, to redraw when the GPS moves it
   Drawn_Own    : Geo.Position   := Ownship.Position;
   Drawn_Status : Ownship.Source := Ownship.Status;

   --  Aircraft whose details panel is open, or Traffic.No_Aircraft
   Selected : Unsigned_32 := Traffic.No_Aircraft;

   --  Aircraft the map is following, or Traffic.No_Aircraft. Never set
   --  together with Following (Ownship). Closing the panel keeps it.
   Followed : Unsigned_32 := Traffic.No_Aircraft;

   --  USER button state at the last tick, to act once per press
   Button_Was_Down : Boolean := False;

   --  After a screenshot, a notice saying so is shown until Notice_Until
   Notice_Time  : constant Time_Span := Milliseconds (2_500);
   Notice_Until : Time               := Time_First;
   Notice_Saved : Boolean            := False;  --  else it failed
   Notice_Shown : Boolean            := False;  --  on screen now

   --  DEBUG: selection last traced to the log
   Logged_Selection : Unsigned_32 := Traffic.No_Aircraft;

   type Touch_Mode is (Idle, Pressing_Control, Touching_Map, Dragging);

   Mode     : Touch_Mode := Idle;
   Up_Count : Natural    := 0;
   Down_X   : Integer    := 0;  --  where the current touch started
   Down_Y   : Integer    := 0;
   Last_X   : Integer    := 0;  --  last position used for panning
   Last_Y   : Integer    := 0;

   ---------
   -- Pan --
   ---------

   --  Move the map with the finger by (DX, DY) screen pixels
   procedure Pan (DX, DY : Integer) is
      P : Geo.World_Pixel := Geo.To_World_Pixel (View_Centre, Zoom);
   begin
      P.X         := P.X - Long_Float (DX);
      P.Y         := P.Y - Long_Float (DY);
      View_Centre := Clamp_To_Coverage (Geo.From_World_Pixel (P, Zoom), Zoom);
      Following   := False;
      Followed    := Traffic.No_Aircraft;
      Redraw      := True;
   end Pan;

   --------------------
   -- Fresh_Position --
   --------------------

   --  Current position of aircraft ICAO, if it has one: True and Pos set
   function Fresh_Position
     (ICAO : Unsigned_32; Pos : out Geo.Position) return Boolean
   is
      S : constant Natural := Traffic.Find (ICAO);
   begin
      Pos := (Lat => 0.0, Lon => 0.0);
      if S = 0 then
         return False;
      end if;

      declare
         A : constant Traffic.Aircraft := Traffic.Get (S);
      begin
         Pos := A.Position;
         return Traffic.Position_Fresh (A, Clock);
      end;
   end Fresh_Position;

   -------------------
   -- Toggle_Follow --
   -------------------

   --  Follow the selected aircraft or stop if it is already followed
   procedure Toggle_Follow is
      Pos : Geo.Position;
   begin
      if Followed = Selected then
         Followed := Traffic.No_Aircraft;
         Debug_Log.Put_Line ("follow: off");
      elsif Fresh_Position (Selected, Pos) then
         Followed  := Selected;
         Following := False;
         Debug_Log.Put_Line ("follow: " & Text_Format.Hex6 (Selected));
      else
         return;  --  no current position: button is greyed out
      end if;
      Redraw := True;
   end Toggle_Follow;

   --------------------
   -- Press_Control --
   --------------------

   procedure Press_Control (C : Control) is
   begin
      case C is
         when Zoom_In =>
            if Zoom < Map_Zoom'Last then
               Zoom := Zoom + 1;
            end if;

         when Zoom_Out =>
            if Zoom > Map_Zoom'First then
               Zoom := Zoom - 1;
            end if;

         when Centre_On_Ownship =>
            Following := True;
            Followed  := Traffic.No_Aircraft;

         when None =>
            return;
      end case;

      if Following then
         View_Centre := Ownship.Position;
      else
         View_Centre := Clamp_To_Coverage (View_Centre, Zoom);
      end if;

      Redraw := True;
      Debug_Log.Put_Line
        (C'Image & ": range" & Positive'Image (Range_NM (Zoom)) & " NM");
   end Press_Control;

   ----------------
   -- Handle_Tap --
   ----------------

   --  A touch on the map released without dragging: select the aircraft
   --  under the finger, or close the details panel if there is none
   procedure Handle_Tap (X, Y : Integer) is
      Picked : constant Unsigned_32 :=
        Overlay.Pick_Aircraft (X, Y, View_Centre, Zoom);
   begin
      Debug_Log.Put_Line
        ("tap at" & X'Image & Y'Image & " -> " &
         (if Picked = Traffic.No_Aircraft then "nothing"
          else Text_Format.Hex6 (Picked)));

      if Picked /= Traffic.No_Aircraft then
         Selected := Picked;
      elsif Selected /= Traffic.No_Aircraft then
         Selected := Traffic.No_Aircraft;
      else
         return;  --  nothing selected and nothing hit: no change
      end if;

      Redraw := True;
   end Handle_Tap;

   -------------------
   -- Handle_Touch --
   -------------------

   procedure Handle_Touch is
      T : constant Touch_Input.Touch_Sample := Touch_Input.Read;
   begin
      if not T.Down then
         Up_Count := Up_Count + 1;
         if Up_Count >= Release_Samples then
            --  Released without becoming a drag: it was a tap
            if Mode = Touching_Map then
               Handle_Tap (Down_X, Down_Y);
            end if;
            Mode := Idle;
         end if;
         return;
      end if;

      Up_Count := 0;

      case Mode is
         when Idle =>
            Down_X := T.X;
            Down_Y := T.Y;
            Last_X := T.X;
            Last_Y := T.Y;

            if Selected /= Traffic.No_Aircraft
              and then Track_Popup.Contains (T.X, T.Y)
            then
               --  Touches on the details panel never reach the map
               if Track_Popup.Close_Hit (T.X, T.Y) then
                  Selected := Traffic.No_Aircraft;
                  Redraw   := True;
               elsif Track_Popup.Follow_Hit (T.X, T.Y) then
                  Toggle_Follow;
               end if;
               Mode := Pressing_Control;

            elsif Hit (T.X, T.Y) /= None then
               --  Act once on touch-down; ignore the rest of this touch
               Press_Control (Hit (T.X, T.Y));
               Mode := Pressing_Control;
            else
               Mode := Touching_Map;
            end if;

         when Pressing_Control =>
            null;

         when Touching_Map =>
            if abs (T.X - Down_X) > Drag_Threshold
              or else abs (T.Y - Down_Y) > Drag_Threshold
            then
               Mode := Dragging;
               Pan (T.X - Last_X, T.Y - Last_Y);
               Last_X := T.X;
               Last_Y := T.Y;
            end if;

         when Dragging =>
            if T.X /= Last_X or else T.Y /= Last_Y then
               Pan (T.X - Last_X, T.Y - Last_Y);
               Last_X := T.X;
               Last_Y := T.Y;
            end if;
      end case;
   end Handle_Touch;

begin
   --  Keep the clocks running while the CPU sleeps
   --  Without this, the display buffer was looking wacky after a cold power-up.
   --  Insane debugging was required to find this...
   STM32_SVD.DBG.DBG_Periph.DBGMCU_CR.DBG_SLEEP   := True;
   STM32_SVD.DBG.DBG_Periph.DBGMCU_CR.DBG_STOP    := True;
   STM32_SVD.DBG.DBG_Periph.DBGMCU_CR.DBG_STANDBY := True;

   Initialize_LEDs;
   All_LEDs_Off;

   Debug_Log.Initialize;
   Debug_Log.Put_Line ("ADS-B radar: start");

   Screen.Initialize;
   Overlay.Draw_Splash ("Reading SD card...");
   Screen.Show;

   Touch_Input.Initialize;
   Configure_User_Button_GPIO;
   Map_View.Initialize;
   Adsbee.Initialize;
   GPS.Initialize;

   Next_Tick           := Clock;
   Next_Heartbeat      := Next_Tick;
   Next_Report         := Next_Tick + Report_Period;
   Next_Redraw         := Next_Tick;
   Next_Traffic_Redraw := Next_Tick;

   loop
      begin
         --  USER button pressed triggers a screenshot.
         --  Sampling once per tick also filters contact bounce.
         declare
            Down : constant Boolean := User_Button_Point.Set;
         begin
            if Down and then not Button_Was_Down then
               Screenshot.Save (Notice_Saved);
               Notice_Until := Clock + Notice_Time;
               Redraw       := True;
            end if;
            Button_Was_Down := Down;
         end;

         --  Take the notice down when its time is up
         if Notice_Shown and then Clock >= Notice_Until then
            Redraw := True;
         end if;

         Handle_Touch;
         Adsbee.Poll;
         GPS.Poll;

         --  New traffic reports: redraw, but not more than twice a second.
         --  (Clock is checked first so a change is not consumed early.)
         if Clock >= Next_Traffic_Redraw and then Traffic.Take_Changed then
            Redraw              := True;
            Next_Traffic_Redraw := Clock + Traffic_Redraw_Interval;
         end if;

         --  Close the details panel if its aircraft has been dropped
         if Selected /= Traffic.No_Aircraft
           and then Traffic.Find (Selected) = 0
         then
            Selected := Traffic.No_Aircraft;
            Redraw   := True;
         end if;

         --  Ownship moved (new GPS fix) or the fix came or went: redraw,
         --  and keep the map on Ownship while following
         if Ownship.Position /= Drawn_Own
           or else Ownship.Status /= Drawn_Status
         then
            Drawn_Own    := Ownship.Position;
            Drawn_Status := Ownship.Status;
            Redraw       := True;
         end if;

         if Following and then View_Centre /= Drawn_Own then
            View_Centre := Drawn_Own;
            Redraw      := True;
         end if;

         --  Keep the map on the followed aircraft. If it was dropped, stop
         --  following. While its position is stale, the map stays put.
         if Followed /= Traffic.No_Aircraft then
            declare
               Pos : Geo.Position;
            begin
               if Traffic.Find (Followed) = 0 then
                  Followed := Traffic.No_Aircraft;
                  Debug_Log.Put_Line ("follow: aircraft dropped");
                  Redraw := True;
               elsif Fresh_Position (Followed, Pos) then
                  Pos := Clamp_To_Coverage (Pos, Zoom);
                  if Pos /= View_Centre then
                     View_Centre := Pos;
                     Redraw      := True;
                  end if;
               end if;
            end;
         end if;

         if Redraw and then Clock >= Next_Redraw then
            Next_Redraw := Clock + Min_Redraw_Interval;
            Map_View.Draw (View_Centre, Zoom);

            --  DEBUG: trace the first frame with a newly selected panel
            if Selected /= Logged_Selection
              and then Selected /= Traffic.No_Aircraft
            then
               Debug_Log.Put_Line
                 ("panel: drawing " & Text_Format.Hex6 (Selected));
            end if;

            Notice_Shown := Clock < Notice_Until;
            Overlay.Draw
              (Ownship.Position, View_Centre, Zoom, Following, Selected,
               Followed,
               Notice =>
                 (if not Notice_Shown then ""
                  elsif Notice_Saved then "SAVED " & Screenshot.Last_File
                  else "SCREENSHOT FAILED"),
               Notice_Error => not Notice_Saved);
            Screen.Show;
            Redraw := False;

            if Selected /= Logged_Selection then
               if Selected /= Traffic.No_Aircraft then
                  Debug_Log.Put_Line ("panel: shown");
               end if;
               Logged_Selection := Selected;
            end if;
         end if;

         if Clock >= Next_Report then
            --  Forget aircraft not heard for a while. Redraw once a second
            --  while any are tracked so stale positions disappear on time.
            Traffic.Expire (Clock);
            if Traffic.Count > 0 then
               Redraw := True;
            end if;

            --  ADS-B receiver: what arrived this second, and every fifth
            --  second the latest aircraft report as a sample
            --  (Framing errors climbing with no lines = the module is at a
            --  different baud rate, e.g. after a firmware update.)
            declare
               S : constant Adsbee.Stats := Adsbee.Take_Stats;
            begin
               Debug_Log.Put_Line
                 ("adsb: lines" & S.Lines'Image & " (#A" & S.Mode_S'Image &
                  ", #U" & S.UAT'Image & ", #S" & S.Status'Image & ", other" &
                  S.Other'Image & ", too long" & S.Too_Long'Image &
                  "), uart overruns" & Adsb_UART.Overruns'Image &
                  ", buffer full" & Adsb_UART.Dropped'Image &
                  ", framing errors" & Adsb_UART.Framing_Errors'Image &
                  ", bad CRC" & S.Bad_Checksum'Image & ", bad format" &
                  S.Bad_Format'Image & ", tracked" & Traffic.Count'Image);

               Report_Count := Report_Count + 1;
               if Report_Count mod 5 = 0
                 and then Adsbee.Last_Aircraft_Line'Length > 0
               then
                  Debug_Log.Put_Line
                    ("adsb last: " & Adsbee.Last_Aircraft_Line);
               end if;
            end;

            --  GPS: sentences this second and the current fix
            declare
               S : constant GPS.Stats    := GPS.Take_Stats;
               F : constant GPS.Fix_Info := GPS.Latest;

               function Two (N : Natural) return String is
                 (Character'Val (Character'Pos ('0') + N / 10 mod 10) &
                  Character'Val (Character'Pos ('0') + N mod 10));
            begin
               Debug_Log.Put_Line
                 ("gps: lines" & S.Lines'Image & " (RMC" & S.RMC'Image &
                  ", GGA" & S.GGA'Image & ", other" & S.Other'Image &
                  ", bad CRC" & S.Bad_Checksum'Image & ", bad format" &
                  S.Bad_Format'Image & ", too long" & S.Too_Long'Image &
                  "), bytes" & GPS_UART.Received'Image & ", lost" &
                  GPS_UART.Lost'Image & ", framing errors" &
                  GPS_UART.Framing_Errors'Image & ", " &
                  (if F.Has_Time then
                     "utc " & Two (F.UTC / 3_600) & ":" &
                     Two (F.UTC / 60 mod 60) & ":" & Two (F.UTC mod 60)
                   else "no time") &
                  ", sats" & F.Satellites'Image & ", " &
                  (case Ownship.Status is
                     when Ownship.Built_In => "no fix yet",
                     when Ownship.Live_Fix =>
                       "fix " &
                       Text_Format.Degrees (F.Position.Lat, 'N', 'S', 2) &
                       " " & Text_Format.Degrees (F.Position.Lon, 'E', 'W', 3),
                     when Ownship.Last_Fix => "fix lost"));
            end;

            Next_Report := Clock + Report_Period;
         end if;

         if Clock >= Next_Heartbeat then
            Toggle (Green_LED);
            Next_Heartbeat := Clock + Heartbeat_Period;
         end if;

      exception
         when E : others =>
            --  Never let one bad frame stop the display: log what went
            --  wrong (GNAT puts file:line in the message of a failed
            --  check), drop the details panel in case it caused it, and
            --  carry on with the next tick.
            Debug_Log.Put_Line
              ("main loop: " & Ada.Exceptions.Exception_Name (E) & ": " &
               Ada.Exceptions.Exception_Message (E));
            Selected := Traffic.No_Aircraft;
            Followed := Traffic.No_Aircraft;
            Redraw   := True;
            Mode     := Idle;
      end;

      --  A map redraw can take longer than one tick; don't try to catch up
      Next_Tick := Next_Tick + Tick_Period;
      if Next_Tick < Clock then
         Next_Tick := Clock + Tick_Period;
      end if;

      delay until Next_Tick;
   end loop;
end Adsb_Radar;
