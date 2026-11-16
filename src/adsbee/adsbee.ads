--  ADSBee 1421 receiver on UART7 (see Adsb_UART).
--
--  The module is configured once and its settings are saved in its own
--  flash (done 2026-11-15 over this link):
--     AT+LOG_LEVEL=SILENT            log text would corrupt the reports
--     AT+PROTOCOL_OUT=CONSOLE,CSBEE  ASCII aircraft reports
--     AT+SETTINGS=SAVE
--  It powers up sending CSBee at Module_Baud, so the board only listens and
--  splits the stream into lines for the parser. No AT commands are sent.
--
--  If nothing arrives after a module firmware update: firmware 0.4.x boots
--  at 115200 and an update may reset the saved settings. Re-run the AT
--  commands above (e.g. from a PC through the RP2040 Programmer).

package Adsbee is

   --  Console baud rate the module powers up at (firmware 0.3.x default)
   Module_Baud : constant := 1_000_000;

   --  Start UART7 at Module_Baud and begin receiving. Never raises.
   procedure Initialize;

   --  Take every byte received so far and split it into lines; parse the
   --  aircraft lines (CSBee) and update the Traffic table. Call once per
   --  main-loop tick. Never raises.
   procedure Poll;

   --  Line counts since the last call to Take_Stats
   type Stats is record
      Lines    : Natural := 0;  --  complete lines of any kind
      Mode_S   : Natural := 0;  --  "#A:" 1090 MHz aircraft reports
      UAT      : Natural := 0;  --  "#U:" 978 MHz aircraft reports
      Status   : Natural := 0;  --  "#S:" receiver statistics
      Other    : Natural := 0;  --  anything else
      Too_Long : Natural := 0;  --  lines over Max_Line, discarded

      --  Aircraft lines rejected by the parser (not added to Traffic)
      Bad_Checksum : Natural := 0;
      Bad_Format   : Natural := 0;
   end record;

   function Take_Stats return Stats;

   --  Most recent "#A:" or "#U:" line, "" if none yet
   function Last_Aircraft_Line return String;

   Max_Line : constant := 255;

end Adsbee;
