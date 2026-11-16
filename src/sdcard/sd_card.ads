--  microSD card on the board's SDMMC1 slot, polled (no DMA). Reads the map
--  tiles; writes are used only for screenshots (see Screenshot).
--
--  The stm32_hal crate's STM32.SDMMC.Initialize has its card
--  identification step commented out, so this package runs the
--  identification itself (SDMMC_Init from adl_middleware). Block reads and
--  writes are this package's own polled routines (see the body for why
--  stm32_hal's are not used).
--  Device can then be mounted with File_IO.Mount_Drive.

with HAL;               use HAL;
with HAL.Block_Drivers; use HAL.Block_Drivers;

package SD_Card is

   type Status_Kind is (Not_Initialized, No_Card, Card_Error, Ready);

   --  Configure the SDMMC pins and clock and identify the card. Leaves
   --  Status = Ready on success. Never raises.
   procedure Initialize;

   function Status return Status_Kind;

   --  Card-detect switch (PC13, low when a card is inserted)
   function Card_Present return Boolean;

   type SD_Block_Device is limited new Block_Driver with null record;

   --  Reads Data'Length / 512 blocks, retrying a failed transfer a few
   --  times. False on any error.
   overriding function Read
     (This : in out SD_Block_Device; Block_Number : UInt64; Data : out Block)
      return Boolean;

   --  Writes Data'Length / 512 blocks, retrying a failed transfer a few
   --  times. Returns once the card has finished programming them. False on
   --  any error.
   overriding function Write
     (This : in out SD_Block_Device; Block_Number : UInt64; Data : Block)
      return Boolean;

   Device : aliased SD_Block_Device;

end SD_Card;
