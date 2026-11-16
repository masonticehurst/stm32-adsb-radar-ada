--  Own-ship position source.
--
--  The position comes from the GT-U7 GPS. Until the first fix arrives
--  (e.g. indoors) the built-in Fixed_Position is used, so the map still
--  opens somewhere useful. If the fix is lost later, the last fix is kept.

with GPS;
with Geo;

package Ownship is

   Fixed_Position : constant Geo.Position := (Lat => 41.51, Lon => -74.00);

   type Source is
     (Built_In,   --  no GPS fix since start-up: Fixed_Position
      Live_Fix,   --  current GPS fix
      Last_Fix);  --  GPS fix lost: the last one it gave

   function Status return Source is
     (if not GPS.Ever_Fixed then Built_In elsif GPS.Has_Fix then Live_Fix
      else Last_Fix);

   function Position return Geo.Position is
     (if GPS.Ever_Fixed then GPS.Latest.Position else Fixed_Position);

end Ownship;
