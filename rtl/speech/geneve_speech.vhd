----------------------------------------------------------------------------------
-- geneve_speech.vhd
--
-- TI Speech Synthesizer (TMS5220 + TMS6100) for the Geneve 9640 MiSTer core, as on
-- the PEB speech adapter card (MAME ti99_speechconn): the card decodes the box
-- addresses; here rs_n / ws_n come from the core. The 32 KiB speech ROM is outside.
--
-- tms5220.vhd, tms6100.vhd: Erik Piehl, EP994A (LGPL), from the TI-99/4A MiSTer core;
-- plc10_speech_synthetizer.vhd: Dar (2014), algorithm from MAME.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.tms5220;
use work.tms6100;

entity geneve_speech is
	generic
	(
		CLK_HALF : integer := 21          -- 21.477 MHz / 42 = 511 kHz
	);
	port
	(
		clk       : in  std_logic;
		reset     : in  std_logic;
		model     : in  std_logic_vector(1 downto 0);   -- 0 default, 1 TMS5200, 2 TMS5220
		rs_n      : in  std_logic;                      -- read strobe (one clk)
		ws_n      : in  std_logic;                      -- write strobe (one clk)
		din       : in  std_logic_vector(7 downto 0);
		dout      : out std_logic_vector(7 downto 0);
		ready_n   : out std_logic;
		aout      : out signed(7 downto 0);
		rom_addr  : out std_logic_vector(14 downto 0);
		rom_data  : in  std_logic_vector(7 downto 0)
	);
end geneve_speech;

architecture rtl of geneve_speech is
	signal add1, add2, add4, add8, add8r, m0, m1 : std_logic;
begin
	tms5220_b : entity work.tms5220
		generic map ( CLK_HALF => CLK_HALF )
		port map (
			model     => model,
			reset     => reset,
			clk_i     => clk,
			ce_n_i    => '0',
			rs_n_i    => rs_n,
			ws_n_i    => ws_n,
			add1_o    => add1,
			add2_o    => add2,
			add4_o    => add4,
			add8_o    => add8,
			add8_i    => add8r,
			m0_o      => m0,
			m1_o      => m1,
			data_i    => din,
			data_o    => dout,
			ready_n_o => ready_n,
			int_n_o   => open,
			aout_o    => aout
		);

	tms6100_b : entity work.tms6100
		port map (
			reset     => reset,
			clk_i     => clk,
			ce_n_i    => '0',
			add1_i    => add1,
			add2_i    => add2,
			add4_i    => add4,
			add8_i    => add8,
			add8_o    => add8r,
			m0_i      => m0,
			m1_i      => m1,
			re_o      => open,
			addr_o    => rom_addr,
			data_i    => rom_data
		);
end rtl;
