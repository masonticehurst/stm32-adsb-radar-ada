package body Traffic is

   use CSBee;

   Table   : array (Slot) of Aircraft;
   Changed : Boolean := False;

   ---------------
   -- Find_Slot --
   ---------------

   --  Slot for ICAO: its existing entry, else a free one, else the one
   --  heard least recently
   function Find_Slot (ICAO : Unsigned_32) return Slot is
      Free   : Natural := 0;
      Oldest : Slot    := Slot'First;
   begin
      for S in Slot loop
         if Table (S).In_Use then
            if Table (S).ICAO = ICAO then
               return S;
            end if;
            if Table (S).Last_Heard < Table (Oldest).Last_Heard then
               Oldest := S;
            end if;
         elsif Free = 0 then
            Free := S;
         end if;
      end loop;

      return (if Free /= 0 then Free else Oldest);
   end Find_Slot;

   ------------
   -- Update --
   ------------

   procedure Update (Report : CSBee.Aircraft_Report; Now : Time) is
      S : constant Slot := Find_Slot (Report.ICAO);
      A : Aircraft renames Table (S);
   begin
      if not A.In_Use or else A.ICAO /= Report.ICAO then
         A := (In_Use => True, ICAO => Report.ICAO, others => <>);
      end if;

      A.Source     := Report.Source;
      A.Airborne   := Airborne (Report);
      A.Last_Heard := Now;

      if Report.Callsign_Len > 0 then
         A.Callsign     := Report.Callsign;
         A.Callsign_Len := Report.Callsign_Len;
      end if;

      --  0,0 is what the receiver sends before it has decoded a position
      if Position_Valid (Report)
        and then (Report.Latitude /= 0.0 or else Report.Longitude /= 0.0)
      then
         A.Has_Position  := True;
         A.Position      := (Lat => Report.Latitude, Lon => Report.Longitude);
         A.Position_Time := Now;
      end if;

      if Baro_Alt_Valid (Report) then
         A.Has_Altitude := True;
         A.Altitude_Ft  := Report.Baro_Alt_Ft;
      elsif GNSS_Alt_Valid (Report) then
         A.Has_Altitude := True;
         A.Altitude_Ft  := Report.GNSS_Alt_Ft;
      end if;

      if Direction_Valid (Report) then
         A.Has_Direction := True;
         A.Direction_Deg := Report.Direction_Deg mod 360;
      end if;

      if Speed_Valid (Report) then
         A.Has_Speed := True;
         A.Speed_Kt  := Report.Speed_Kt;
      end if;

      if Baro_VRate_Valid (Report) then
         A.Has_VRate := True;
         A.VRate_Fpm := Report.Baro_VRate_Fpm;
      elsif GNSS_VRate_Valid (Report) then
         A.Has_VRate := True;
         A.VRate_Fpm := Report.GNSS_VRate_Fpm;
      end if;

      Changed := True;
   end Update;

   ------------
   -- Expire --
   ------------

   procedure Expire (Now : Time) is
   begin
      for A of Table loop
         if A.In_Use and then Now - A.Last_Heard > Drop_Timeout then
            A.In_Use := False;
            Changed  := True;
         end if;
      end loop;
   end Expire;

   ----------
   -- Find --
   ----------

   function Find (ICAO : Unsigned_32) return Natural is
   begin
      for S in Slot loop
         if Table (S).In_Use and then Table (S).ICAO = ICAO then
            return S;
         end if;
      end loop;
      return 0;
   end Find;

   ---------
   -- Get --
   ---------

   function Get (S : Slot) return Aircraft is (Table (S));

   -----------
   -- Count --
   -----------

   function Count return Natural is
      N : Natural := 0;
   begin
      for A of Table loop
         if A.In_Use then
            N := N + 1;
         end if;
      end loop;
      return N;
   end Count;

   ------------------
   -- Take_Changed --
   ------------------

   function Take_Changed return Boolean is
      Was : constant Boolean := Changed;
   begin
      Changed := False;
      return Was;
   end Take_Changed;

end Traffic;
