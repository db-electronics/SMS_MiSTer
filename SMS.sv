//============================================================================
//  SMS replica
// 
//  Port to MiSTer
//  Copyright (C) 2017,2018 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [44:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output  [7:0] VIDEO_ARX,
	output  [7:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S, // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)
	input         TAPE_IN,

	// SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE
);

assign {SD_SCK, SD_MOSI, SD_CS} = '1;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign LED_USER  = ioctl_download | bk_state;
assign LED_DISK  = 0;
assign LED_POWER = 0;

assign VIDEO_ARX = status[9] ? 8'd16 : 8'd4;
assign VIDEO_ARY = status[9] ? 8'd9  : 8'd3;

`include "build_id.v"
parameter CONF_STR1 = {
	"SMS;;",
	"-;",
	"FS,SMS;",
	"-;"
};
parameter CONF_STR2 = {
	"AB,Save Slot,1,2,3,4;"
};
parameter CONF_STR3 = {
	"6,Load state;"
};
parameter CONF_STR4 = {
	"7,Save state;",
	"-;",
	"O9,Aspect ratio,4:3,16:9;",
	"O34,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"O2,TV System,NTSC,PAL;",
	"-;",
	"O1,Swap joysticks,No,Yes;",
	"-;",
	"RA,Reset;",
	"J1,Fire 1,Fire 2,Pause;",
	"V,v1.0.",`BUILD_DATE
};


////////////////////   CLOCKS   ///////////////////

wire locked;
wire clk_sys = clk_cpu;
wire clk_mem;
wire clk_cpu;
wire clk_vid;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),
	.outclk_1(SDRAM_CLK),
	//.outclk_2(clk_cpu),
	.outclk_3(clk_vid),
	.locked(locked)
);

wire cold_reset = RESET | status[0] | ~initReset_n;
wire reset = cold_reset | buttons[1] | status[10] | ioctl_download | bk_loading;

reg initReset_n = 0;
always @(posedge clk_sys) begin
	integer timeout = 0;
	
	if(timeout < 5000000) timeout <= timeout + 1;
	else initReset_n <= 1;
end

//////////////////   HPS I/O   ///////////////////
wire [15:0] joy_0;
wire [15:0] joy_1;
wire  [1:0] buttons;
wire [31:0] status;

wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_download;
wire  [7:0] ioctl_index;

reg  [31:0] sd_lba;
reg         sd_rd = 0;
reg         sd_wr = 0;
wire        sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din;
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;

wire        forced_scandoubler;


hps_io #(.STRLEN(($size(CONF_STR1)>>3) + ($size(CONF_STR2)>>3) + ($size(CONF_STR3)>>3) + ($size(CONF_STR4)>>3) + 3), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.conf_str({CONF_STR1,bk_ena ? "O" : "+",CONF_STR2,bk_ena ? "R" : "+",CONF_STR3,bk_ena ? "R" : "+",CONF_STR4}),

	.joystick_0(joy_0),
	.joystick_1(joy_1),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),

	.ps2_kbd_led_use(0),
	.ps2_kbd_led_status(0),

	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),

	.sd_conf(0),
	.ioctl_wait(0),
	
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size)
);

wire [21:0] ram_addr;
wire  [7:0] ram_dout;
wire        ram_rd;

sdram ram
(
	.*,
	.init(~locked),
	.clk(clk_mem),
	.clk_ref(clk_cpu),
	.dout(ram_dout),
	.din (ioctl_dout),
	.addr(ioctl_download ? ioctl_addr : {ram_addr[21:14] & cart_sz, ram_addr[13:0]}),
	.wtbt(0),
	.we(ioctl_wr),
	.rd(ram_rd),
	.ready()
);

//	GENERIC
//	(
//		init_file			: string := "none";
//		widthad_a			: natural;
//		width_a				: natural := 8;
//    outdata_reg_a : string := "UNREGISTERED"
//spram #(.widthad_a(18)) ram
//(
////	.address(ioctl_download ? ioctl_addr : {ram_addr[21:14] & cart_sz, ram_addr[13:0]}),
//	.address(ioctl_download ? ioctl_addr : {ram_addr[17:14] & cart_sz[3:0], ram_addr[13:0]}),
//	.clock(clk_mem),
//	.data(ioctl_dout),
//	.wren(ioctl_wr),
//	.q(ram_dout)
//);

wire [5:0] audio;

assign AUDIO_L = {audio, audio, audio[5:3]};
assign AUDIO_R = AUDIO_L;
assign AUDIO_S = 0;
assign AUDIO_MIX = 0;

wire [6:0] joya = status[1] ? ~joy_1[6:0] : ~joy_0[6:0];
wire [6:0] joyb = status[1] ? ~joy_0[6:0] : ~joy_1[6:0];

reg  dbr = 0;
always @(posedge clk_sys) begin
	if(ioctl_download || bk_loading) dbr <= 1;
end

wire [7:0] cart_sz = ioctl_addr[21:14]-1'd1;

system system
(
	.clk_cpu(clk_cpu),
	.clk_vdp(clk_vdp),
	.clk_pix(clk_pix),
	.clk_sys(clk_sys),

	.rom_rd(ram_rd),
	.rom_a(ram_addr),
	.rom_do(ram_dout),

	.j1_up(joya[3]),
	.j1_down(joya[2]),
	.j1_left(joya[1]),
	.j1_right(joya[0]),
	.j1_tl(joya[4]),
	.j1_tr(joya[5]),
	.j2_up(joyb[3]),
	.j2_down(joyb[2]),
	.j2_left(joyb[1]),
	.j2_right(joyb[0]),
	.j2_tl(joyb[4]),
	.j2_tr(joyb[5]),
	.reset(~reset),
	.pause(joya[6]&joyb[6]),

	.x(x),
	.y(y),
	.color(color),
	.audio(audio),

	.dbr(dbr),
	
   .add_bk({sd_lba[5:0],sd_buff_addr}),
	.data_bk(sd_buff_dout),
	.wren_bk(sd_buff_wr & sd_ack),
	.q_bk(sd_buff_din)
);

wire [8:0] x;
wire [7:0] y;
wire [5:0] color;

video video
(
	.clk8(clk_pix),
	.pal(status[2]),
	.x(x),
	.y(y),

	.hsync(HSync),
	.vsync(VSync),
	.hblank(HBlank),
	.vblank(VBlank)
);

reg [4:0] clkd;
reg clk_vdp;
reg clk_pix;
always @(posedge clk_vid) begin

	clk_vdp <= 0;//div5
	clk_pix <= 0;//div10
	clk_cpu <= 0;//div15
	clkd <= clkd + 1'd1;
	if (clkd=='b11101) begin
		clkd <= 'b00000;
		clk_vdp <= 1;
		clk_pix <= 1;
		clk_cpu <= 1;
	end else if (clkd=='b11000) begin
		clk_vdp <= 1;
	end else if (clkd=='b10011) begin
		clk_vdp <= 1;
		clk_pix <= 1;
	end else if (clkd=='b01110) begin
		clk_vdp <= 1;
		clk_cpu <= 1;
	end else if (clkd=='b01001) begin
		clk_vdp <= 1;
		clk_pix <= 1;
	end else if (clkd=='b00100) begin
		clk_vdp <= 1;
	end
end

wire HSync, VSync;
wire HBlank, VBlank;

wire [1:0] scale = status[4:3];

assign CLK_VIDEO = clk_vid;

video_mixer #(.HALF_DEPTH(1), .LINE_LENGTH(300)) video_mixer
(
	.*,
	.clk_sys(clk_vid),
	.ce_pix_out(CE_PIXEL),
	.ce_pix(clk_pix),
	
	.scanlines({scale == 3, scale == 2}),
	.scandoubler(scale || forced_scandoubler),
	.hq2x(scale==1),
	.mono(0),

	.R({4{color[1:0]}}),
	.G({4{color[3:2]}}),
	.B({4{color[5:4]}})
);


/////////////////////////  STATE SAVE/LOAD  /////////////////////////////

wire downloading = ioctl_download;
reg bk_ena = 0;
always @(posedge clk_sys) begin
	reg old_downloading = 0;
	
	old_downloading <= downloading;
	if(~old_downloading & downloading) bk_ena <= 0;
	
	//Save file always mounted in the end of downloading state.
	if(downloading && img_mounted && img_size && !img_readonly) bk_ena <= 1;
end

wire bk_load    = status[6];
wire bk_save    = status[7];
reg  bk_loading = 0;
reg  bk_state   = 0;

always @(posedge clk_sys) begin
	reg old_load = 0, old_save = 0, old_ack;

	old_load <= bk_load & bk_ena;
	old_save <= bk_save & bk_ena;
	old_ack  <= sd_ack;
	
	if(~old_ack & sd_ack) {sd_rd, sd_wr} <= 0;
	
	if(!bk_state) begin
		if((~old_load & bk_load) | (~old_save & bk_save)) begin
			bk_state <= 1;
			bk_loading <= bk_load;
			sd_lba <= {status[11:10],6'd0};
			sd_rd <=  bk_load;
			sd_wr <= ~bk_load;
		end
	end else begin
		if(old_ack & ~sd_ack) begin
			if(&sd_lba[5:0]) begin
				bk_loading <= 0;
				bk_state <= 0;
			end else begin
				sd_lba <= sd_lba + 1'd1;
				sd_rd  <=  bk_loading;
				sd_wr  <= ~bk_loading;
			end
		end
	end
end

endmodule


