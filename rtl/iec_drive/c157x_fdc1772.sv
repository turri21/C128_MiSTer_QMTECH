// Floppy disk controller of the 1570/1571.
//
// Based on fdc1772.v by Till Harbaum <till@harbaum.org>, modified to process externally generated MFM bit stream
//
// Only commands used by 1571:
//   18 -- 0001 1000 -- I   -- seek sector, disable spin up, verify off, 6ms step rate
//   88 -- 1000 1000 -- II  -- read sector, single sector, no delay
//   A8 -- 1010 1000 -- II  -- write sector, single sectors, no delay, enable write pre-comp, write normal data mark
//   C8 -- 1100 1000 -- III -- read address, disable spin up, no delay
//   F8 -- 1111 1000 -- III -- write track, disable spin up, no delay, enable write pre-comp
//   D0 -- 1101 0000 -- IV  -- force interrupt, terminate without interrupt

module c157x_fdc1772
(
    input            clkcpu, // system cpu clock.
    input            clk8m_en,

    // external set signals
    // input      [W:0] floppy_drive,
    input            floppy_reset,
    input            floppy_present,
    // input            floppy_side,
    input            floppy_motor,
    output           floppy_ready,
    input            floppy_index,
    input            floppy_wprot,
    input            floppy_track00,

    // control signals
    output reg       irq,
    output reg       drq, // data request
    output           busy,

    // signals to/from heads
    input            hclk,
    output           ht,
    input            hf,
    output           wgate,

    // CPU interface
    input      [1:0] cpu_addr,
    input            cpu_sel,
    input            cpu_rw,
    input      [7:0] cpu_din,
    output reg [7:0] cpu_dout
);

assign busy = cmd_busy;

// module fdc1772 (
// 	input            clkcpu, // system cpu clock.
// 	input            clk8m_en,

// 	// external set signals
// 	input      [W:0] floppy_drive,
// 	input            floppy_side, 
// 	input            floppy_reset,
// 	output           floppy_step,
// 	input            floppy_motor,
// 	output           floppy_ready,

// 	// interrupts
// 	output reg       irq,
// 	output reg       drq, // data request

// 	input      [1:0] cpu_addr,
// 	input            cpu_sel,
// 	input            cpu_rw,
// 	input      [7:0] cpu_din,
// 	output reg [7:0] cpu_dout,

// 	// place any signals that need to be passed up to the top after here.
// 	input      [W:0] img_mounted, // signaling that new image has been mounted
// 	input      [W:0] img_wp,      // write protect
// 	input            img_ds,      // double-sided image (for BBC Micro only)
// 	input     [31:0] img_size,    // size of image in bytes
// 	output reg[31:0] sd_lba,
// 	output reg [W:0] sd_rd,
// 	output reg [W:0] sd_wr,
// 	input            sd_ack,
// 	input      [8:0] sd_buff_addr,
// 	input      [7:0] sd_dout,
// 	output     [7:0] sd_din,
// 	input            sd_dout_strobe
// );

parameter CLK_EN           = 16'd8000; // in kHz
// parameter FD_NUM           = 1;    // number of supported floppies
parameter MODEL            = 0;    // 0 - wd1770, 1 - fd1771, 2 - wd1772, 3 = wd1773/fd1793
// parameter EXT_MOTOR        = 1'b1; // != 0 if motor is controlled externally by floppy_motor
parameter INVERT_HEAD_RA   = 1'b0; // != 0 - invert head in READ_ADDRESS reply

parameter SYNC_A1_PATTERN  = 16'h4489; // "A1" sync pattern
parameter SYNC_C2_PATTERN  = 16'h5224; // "C2" sync pattern
parameter SYNC_A1_CRC      = 16'hCDB4; // CRC after 3 "A1" syncs

// localparam IMG_ARCHIE      = 0;
// localparam IMG_ST          = 1;
// localparam IMG_BBC         = 2; // SSD, DSD formats
// localparam IMG_TI99        = 3; // V9T9 format

// parameter  IMG_TYPE        = IMG_ARCHIE;

// localparam W    = FD_NUM - 1;
// localparam WIDX = $clog2(FD_NUM);

localparam INDEX_PULSE_CYCLES = 16'd5*CLK_EN;                                // duration of an index pulse, 5ms
localparam SETTLING_DELAY     = MODEL == 2 ? 19'd15*CLK_EN : 19'd30*CLK_EN;  // head settling delay, 15 ms (WD1772) or 30 ms (others)
localparam MIN_BUSY_TIME      = 16'd6*CLK_EN;                                // minimum busy time, 6ms

// // -------------------------------------------------------------------------
// // --------------------- IO controller image handling ----------------------
// // -------------------------------------------------------------------------

// reg  [10:0] fdn_sector_len[FD_NUM];
// reg   [4:0] fdn_spt[FD_NUM];     // sectors/track
// reg   [9:0] fdn_gap_len[FD_NUM]; // gap len/sector
// reg         fdn_doubleside[FD_NUM];
// reg         fdn_hd[FD_NUM];
// reg         fdn_fm[FD_NUM];
// reg         fdn_present[FD_NUM];

// reg  [11:0] image_sectors;
// reg  [11:0] image_sps; // sectors/side
// reg   [4:0] image_spt; // sectors/track
// reg   [9:0] image_gap_len;
// reg         image_doubleside;
// wire        image_hd = img_size[20];
// reg         image_fm;

// reg   [1:0] sector_size_code; // sec size 0=128, 1=256, 2=512, 3=1024
// reg  [10:0] sector_size;
// reg         sector_base; // number of first sector on track (archie 0, dos 1)

// always @(*) begin
// 	case (IMG_TYPE)
// 	IMG_ARCHIE: begin
// 		// archie, 1024 bytes/sector
// 		sector_size_code = 2'd3;
// 		sector_base = 0;
// 		sd_lba = {(16'd0 + (fd_spt*track[6:0]) << fd_doubleside) + (floppy_side ? 5'd0 : fd_spt) + sector[4:0], s_odd };

// 		image_fm = 0;
// 		image_sectors = img_size[21:10];
// 		image_doubleside = 1'b1;
// 		image_spt = image_hd ? 5'd10 : 5'd5;
// 		image_gap_len = 10'd220;

// 	end
// 	IMG_ST: begin
// 		// this block is valid for the .st format (or similar arrangement), 512 bytes/sector
// 		sector_size_code = 2'd2;
// 		sector_base = 1;
// 		sd_lba = ((fd_spt*track[6:0]) << fd_doubleside) + (floppy_side ? 5'd0 : fd_spt) + sector[4:0] - 1'd1;

// 		image_fm = 0;
// 		image_sectors = img_size[20:9];
// 		image_doubleside = 1'b0;
// 		image_sps = image_sectors;
// 		if (image_sectors > (85*12)) begin
// 			image_doubleside = 1'b1;
// 			image_sps = image_sectors >> 1'b1;
// 		end
// 		if (image_hd) image_sps = image_sps >> 1'b1;

// 		// spt : 9-12, tracks: 79-85
// 		case (image_sps)
// 			711,720,729,738,747,756,765   : image_spt = 5'd9;
// 			790,800,810,820,830,840,850   : image_spt = 5'd10;
// 			948,960,972,984,996,1008,1020 : image_spt = 5'd12;
// 			default : image_spt = 5'd11;
// 		endcase;

// 		if (image_hd) image_spt = image_spt << 1'b1;

// 		// SECTOR_GAP_LEN = BPT/SPT - (SECTOR_LEN + SECTOR_HDR_LEN) = 6250/SPT - (512+6)
// 		case (image_spt)
// 			5'd9, 5'd18: image_gap_len = 10'd176;
// 			5'd10,5'd20: image_gap_len = 10'd107;
// 			5'd11,5'd22: image_gap_len = 10'd50;
// 			default : image_gap_len = 10'd2;
// 		endcase;
// 	end
// 	IMG_BBC, IMG_TI99: begin
// 		// 256 bytes/sector single density (BBC SSD/DSD, TI99/4A)
// 		sector_size_code = 2'd1;
// 		sector_base = 0;
// 		if (IMG_TYPE == IMG_BBC) begin
// 			sd_lba = (((fd_spt*track[6:0]) << fd_doubleside) + (floppy_side ? 5'd0 : fd_spt) + sector[4:0]) >> 1;
// 			image_spt = 10;
// 		end else begin
// 			sd_lba = (fd_spt*(floppy_side ? track[5:0] : 79-track[5:0]) + sector[4:0]) >> 1;
// 			image_spt = 9;
// 		end

// 		image_fm = 1;
// 		image_sectors = img_size[19:8];
// 		image_doubleside = img_ds;
// 		if (img_ds)
// 			image_sps = image_sectors >> 1'b1;
// 		else
// 			image_sps = image_sectors;
// 		image_gap_len = 10'd50;
// 	end
// 	default: begin
// 		sector_size_code = 2'd0;
// 		sector_base = 0;
// 		sd_lba = 0;
// 		image_fm = 0;
// 		image_sectors = 0;
// 		image_doubleside = 0;
// 		image_spt = 0;
// 		image_gap_len = 0;
// 	end

// 	endcase

// 	sector_size = 11'd128 << sector_size_code;
// end

// always @(posedge clkcpu) begin
// 	reg [W:0] img_mountedD;
// 	integer i;
// 	img_mountedD <= img_mounted;
    
// 	for(i = 0; i < FD_NUM; i = i+1'd1) begin
// 		if (~img_mountedD[i] && img_mounted[i]) begin
// 			fdn_present[i] <= |img_size;
// 			fdn_sector_len[i] <= sector_size;
// 			fdn_spt[i] <= image_spt;
// 			fdn_gap_len[i] <= image_gap_len;
// 			fdn_doubleside[i] <= image_doubleside;
// 			fdn_hd[i] <= image_hd;
// 			fdn_fm[i] <= image_fm;
// 		end
// 	end
// end

// -------------------------------------------------------------------------
// ---------------------------- IRQ/DRQ handling ---------------------------
// -------------------------------------------------------------------------
reg cpu_selD;
reg cpu_rwD;
always @(posedge clkcpu) begin
    cpu_rwD <= cpu_sel & ~cpu_rw;
    cpu_selD <= cpu_sel;
end

wire cpu_we = cpu_sel & ~cpu_rw & ~cpu_rwD;

// floppy_reset and read of status register/write of command register clears irq
reg cpu_rw_cmdstatus;
always @(posedge clkcpu)
  cpu_rw_cmdstatus <= ~cpu_selD && cpu_sel && cpu_addr == FDC_REG_CMDSTATUS;

wire status_clr = !floppy_reset || cpu_rw_cmdstatus;

reg irq_set;

always @(posedge clkcpu) begin
    if(status_clr) irq <= 1'b0;
    else if(irq_set) irq <= 1'b1;
end

// floppy_reset and read/write of data register read clears drq

reg drq_set;

reg cpu_rw_data;
always @(posedge clkcpu)
    cpu_rw_data <= ~cpu_selD && cpu_sel && cpu_addr == FDC_REG_DATA;

wire drq_clr = !floppy_reset || cpu_rw_data;

always @(posedge clkcpu) begin
    if(drq_clr) drq <= 1'b0;
    else if(drq_set) drq <= 1'b1;
end

// -------------------------------------------------------------------------
// -------------------- virtual floppy drive mechanics ---------------------
// -------------------------------------------------------------------------

// wire       fdn_index[FD_NUM];
// wire       fdn_ready[FD_NUM];
// wire [6:0] fdn_track[FD_NUM];
// wire [4:0] fdn_sector[FD_NUM];
// wire       fdn_sector_hdr[FD_NUM];
// wire       fdn_sector_data[FD_NUM];
// wire       fdn_dclk[FD_NUM];

// generate
// 	genvar i;
    
// 	for(i=0; i < FD_NUM; i = i+1) begin :fdd

// 		floppy #(.CLK_EN(CLK_EN)) floppy
// 		(
// 			.clk         ( clkcpu             ),
// 			.clk8m_en    ( clk8m_en           ),

// 			// control signals into floppy
// 			.select      ( fd_any && fdn == i ),
// 			.motor_on    ( fd_motor           ),
// 			.step_in     ( step_in            ),
// 			.step_out    ( step_out           ),

// 			// physical parameters
// 			.sector_len  ( fdn_sector_len[i]  ),
// 			.spt         ( fdn_spt[i]         ),
// 			.sector_gap_len ( fdn_gap_len[i]  ),
// 			.sector_base ( sector_base        ),
// 			.hd          ( fdn_hd[i]          ),
// 			.fm          ( fdn_fm[i]          ),

// 			// status signals generated by floppy
// 			.dclk_en     ( fdn_dclk[i]        ),
// 			.track       ( fdn_track[i]       ),
// 			// .sector      ( fdn_sector[i]      ),
// 			// .sector_hdr  ( fdn_sector_hdr[i]  ),
// 			// .sector_data ( fdn_sector_data[i] ),
// 			.ready       ( fdn_ready[i]       )
// 			// .index       ( fdn_index[i]       )
// 		);
// 	end
// endgenerate

// -------------------------------------------------------------------------
// ----------------------------- floppy demux ------------------------------
// -------------------------------------------------------------------------

// reg [WIDX:0] fdn;
// always begin
// 	integer i;
    
// 	fdn = 0;
// 	for(i = FD_NUM-1; i >= 0; i = i - 1) if(!floppy_drive[i]) fdn = i[WIDX:0];
// end

// wire       fd_any         = ~&floppy_drive;

// wire       fd_index       = floppy_index; //fd_any ? fdn_index[fdn]       : 1'b0;
// wire       fd_ready       = fd_any ? fdn_ready[fdn]       : 1'b0;
// wire [6:0] fd_track       = fd_any ? fdn_track[fdn]       : 7'd0;
// wire [4:0] fd_sector      = fd_any ? fdn_sector[fdn]      : 5'd0;
// wire       fd_sector_hdr  = fd_any ? fdn_sector_hdr[fdn]  : 1'b0;
// //wire     fd_sector_data = fd_any ? fdn_sector_data[fdn] : 1'b0;
// wire       fd_dclk_en     = fd_any ? fdn_dclk[fdn]        : 1'b0;
// wire       fd_present     = fd_any ? fdn_present[fdn]     : 1'b0;
// wire       fd_writeprot   = floppy_wprot; //fd_any ? img_wp[fdn]          : 1'b1;

// wire       fd_doubleside  = fdn_doubleside[fdn];
// wire [4:0] fd_spt         = fdn_spt[fdn];

reg       fd_index;
wire      fd_ready = floppy_motor;
wire      fd_dclk_en = clk8m_en & aligned;
reg [7:0] fd_track;
reg [7:0] fd_sector;
// reg       fd_sector_hdr_start;
reg       fd_sector_hdr_valid;
// reg       fd_sector_data_start;
wire      fd_present = floppy_present;
wire      fd_writeprot = floppy_wprot;
// wire      fd_side = floppy_side;
wire      fd_trk00 = floppy_track00;
reg [4:0] fd_spt;

assign floppy_ready = fd_ready && fd_present;

// -------------------------------------------------------------------------
// ----------------------- internal state machines -------------------------
// -------------------------------------------------------------------------

// ------------------------- Index pulse handling --------------------------

reg indexD;

localparam INDEX_COUNT_START = 3'd6;
reg [2:0] index_pulse_counter;

always @(posedge clkcpu) begin
    reg        last_floppy_index;
    reg [18:0] index_pulse_cnt;

    last_floppy_index <= floppy_index;
    if (!floppy_reset || !fd_present) begin
        index_pulse_cnt <= 0;
        fd_index <= 1'b0;
    end
    else if (last_floppy_index && ~floppy_index) begin
        index_pulse_cnt <= INDEX_PULSE_CYCLES;
        fd_index <= 1'b1;
    end
    else if (clk8m_en) begin
        if (index_pulse_cnt != 0) begin
            index_pulse_cnt <= index_pulse_cnt - 19'd1;
        end
        else
            fd_index <= 1'b0;
    end
end

// --------------------------- Motor handling ------------------------------

// if motor is off and type 1 command with "spin up sequnce" bit 3 set
// is received then the command is executed after the motor has
// reached full speed for 5 rotations (800ms spin-up time + 5*200ms =
// 1.8sec) If the floppy is idle for 10 rotations (2 sec) then the
// motor is switched off again
localparam MOTOR_IDLE_COUNTER = 4'd10;
reg [3:0] motor_timeout_index /* verilator public */;
reg cmd_busy;
// reg step_in, step_out;
reg [3:0] motor_spin_up_sequence /* verilator public */;

// wire fd_motor = EXT_MOTOR ? floppy_motor : motor_on;

// consider spin up done either if the motor is not supposed to spin at all or
// if it's supposed to run and has left the spin up sequence
wire motor_spin_up_done = (!motor_on) || (motor_on && (motor_spin_up_sequence == 0));

// ---------------------------- step handling ------------------------------

// localparam STEP_PULSE_LEN = 16'd1;
// localparam STEP_PULSE_CLKS = STEP_PULSE_LEN * CLK_EN;
// reg [15:0] step_pulse_cnt;

// the step rate is only valid for command type I
wire [15:0] step_rate_clk = 
           (cmd[1:0]==2'b00)               ? (16'd6 *CLK_EN-1'd1):   //  6ms
           (cmd[1:0]==2'b01)               ? (16'd12*CLK_EN-1'd1):   // 12ms
           (MODEL == 2 && cmd[1:0]==2'b10) ? (16'd2 *CLK_EN-1'd1):   //  2ms
           (cmd[1:0]==2'b10)               ? (16'd20*CLK_EN-1'd1):   // 20ms
           (MODEL == 2)                    ? (16'd3 *CLK_EN-1'd1):   //  3ms
                                             (16'd30*CLK_EN-1'd1);   // 30ms

reg [15:0] step_rate_cnt;
reg [23:0] delay_cnt;

// assign floppy_step = step_in | step_out;

// flag indicating that a "step" is in progress
wire step_busy = (step_rate_cnt != 0);
wire delaying = (delay_cnt != 0);

// wire fd_track0 = (fd_track == 0);

reg [7:0] step_to;
reg RNF;
reg ctl_busy;
reg idle;
reg sector_inc_strobe;
reg track_inc_strobe;
reg track_dec_strobe;
reg track_clear_strobe;
reg address_update_strobe;

always @(posedge clkcpu) begin
    reg  [1:0] seek_state;
    reg        notready_wait;
    reg        irq_req;
    // reg  [1:0] data_transfer_state;
    reg [15:0] min_busy_cnt;

    sector_inc_strobe <= 1'b0;
    track_inc_strobe <= 1'b0;
    track_dec_strobe <= 1'b0;
    track_clear_strobe <= 1'b0;
    address_update_strobe <= 1'b0;
    
    irq_set <= 1'b0;
    irq_req <= 1'b0;
    data_transfer_start <= 1'b0;

    if(status_clr && !cmd_busy) idle <= 1'b1;

    if(!floppy_reset) begin
        motor_on <= 1'b0;
        idle <= 1'b1;
        ctl_busy <= 1'b0;
        cmd_busy <= 1'b0;
        // fd_track <= 7'd0;
        // step_in <= 1'b0;
        // step_out <= 1'b0;
        // sd_card_read <= 0;
        // sd_card_write <= 0;
        check_crc <= 1'b0;
        seek_state <= 0;
        notready_wait <= 1'b0;
        // data_transfer_state <= 2'b00;
        RNF <= 1'b0;
        index_pulse_counter <= 0;
    end else if (clk8m_en) begin
        // sd_card_read <= 0;
        // sd_card_write <= 0;

        // disable step signal after 1 msec
        // if(step_pulse_cnt != 0) 
        // 	step_pulse_cnt <= step_pulse_cnt - 16'd1;
        // else begin
        // 	step_in <= 1'b0;
        // 	step_out <= 1'b0;
        // end

         // step rate timer
        if(step_rate_cnt != 0) 
            step_rate_cnt <= step_rate_cnt - 16'd1;

        // delay timer
        if(delay_cnt != 0) 
            delay_cnt <= delay_cnt - 1'd1;

        if (!ctl_busy)
            check_crc <= 0;

        // minimum busy timer
        if(min_busy_cnt != 0)
            min_busy_cnt <= min_busy_cnt - 1'd1;
        else if(!ctl_busy) begin
            cmd_busy <= 1'b0;
            irq_set <= irq_req;
        end

        // just received a new command
        if(cmd_rx) begin
            idle <= 1'b0;
            ctl_busy <= 1'b1;
            cmd_busy <= 1'b1;
            min_busy_cnt <= MIN_BUSY_TIME;
            notready_wait <= 1'b0;
            // data_transfer_state <= 2'b00;
            check_crc <= 1'b0;

            if(cmd_type_1 || cmd_type_2 || cmd_type_3) begin
                RNF <= 1'b0;
                motor_on <= 1'b1;
                // 'h' flag '0' -> wait for spin up
                if (!motor_on && !cmd[3]) motor_spin_up_sequence <= 6;   // wait for 6 full rotations
            end

            if(cmd_type_2 || cmd_type_3)
                index_pulse_counter <= INDEX_COUNT_START;

            // handle "forced interrupt"
            if(cmd_type_4) begin
                ctl_busy <= 1'b0;
                cmd_busy <= 1'b0;
                min_busy_cnt <= 0;
                // From Hatari: Starting a Force Int command when idle should set the motor bit and clear the spinup bit (verified on STF)
                if (!ctl_busy) motor_on <= 1'b1;
            end
        end

        if(cmd_type_4 && cmd[3]) irq_req <= 1'b1;

        // execute command if motor is not supposed to be running or
        // wait for motor spinup to finish
        if(ctl_busy && motor_spin_up_done && !step_busy && !delaying) begin

            // ------------------------ TYPE I -------------------------
            if(cmd_type_1) begin
                if(!fd_present) begin
                    // no image selected -> send irq after 6 ms
                    if (!notready_wait) begin
                        delay_cnt <= 16'd6*CLK_EN;
                        notready_wait <= 1'b1;
                    end else begin
                        RNF <= 1'b1;
                        ctl_busy <= 1'b0;
                        irq_set <= 1'b1; // emit irq when command done
                    end
                end else
                // evaluate command
                case (seek_state)
                0: begin
                    // restore / seek
                    if(cmd[7:5] == 3'b000) begin
                        if (track == step_to) seek_state <= 2;
                        else begin
                            step_dir <= (step_to < track);
                            seek_state <= 1;
                        end
                    end

                    // step
                    if(cmd[7:5] == 3'b001) seek_state <= 1;

                    // step-in
                    if(cmd[7:5] == 3'b010) begin
                        step_dir <= 1'b0;
                        seek_state <= 1;
                    end

                    // step-out
                    if(cmd[7:5] == 3'b011) begin
                        step_dir <= 1'b1;
                        seek_state <= 1;
                    end
                end

                // do the step
                1: begin
                    // if (step_dir)
                    // 	fd_track <= fd_track - 7'd1;
                    // else
                    // 	fd_track <= fd_track + 7'd1;

                    // update the track register if seek/restore or the update flag set
                    if( (!cmd[6] && !cmd[5]) || ((cmd[6] || cmd[5]) && cmd[4]))
                        if (step_dir)
                            track_dec_strobe <= 1'b1;
                        else
                            track_inc_strobe <= 1'b1;

                    // step_pulse_cnt <= STEP_PULSE_CLKS - 1'd1;
                    step_rate_cnt <= step_rate_clk;

                    seek_state <= (!cmd[6] && !cmd[5]) ? 0 : 2; // loop for seek/restore
                end

                // verify
                2: begin
                    if (cmd[2]) begin
                        delay_cnt <= SETTLING_DELAY; // TODO: implement verify, now just delay
                    end
                    seek_state <= 3;
                end

                // finish
                3: begin
                    ctl_busy <= 1'b0;
                    irq_req <= 1'b1; // emit irq when command done
                    seek_state <= 0;
                end
                endcase
            end // if (cmd_type_1)

            // ------------------------ TYPE II -------------------------
            if(cmd_type_2) begin
                // read/write sector
                if(!fd_present) begin
                    // no image selected -> send irq after 6 ms
                    if (!notready_wait) begin
                        delay_cnt <= 16'd6*CLK_EN;
                        notready_wait <= 1'b1;
                    end else begin
                        RNF <= 1'b1;
                        ctl_busy <= 1'b0;
                        irq_set <= 1'b1; // emit irq when command done
                    end
                end else if(cmd[2] && !notready_wait) begin
                    // e flag: 15/30 ms settling delay
                    delay_cnt <= SETTLING_DELAY;
                    notready_wait <= 1'b1;
                    // read sector
                end else if((!cmd_rx && index_pulse_counter == 0) || data_transfer_done) begin
                    if (!data_transfer_done)
                        RNF <= 1;

                    if (data_transfer_done && cmd[4]) begin
                        sector_inc_strobe <= 1'b1; // multiple sector transfer
                    end else begin
                        ctl_busy <= 1'b0;
                        irq_req <= 1'b1; // emit irq when command done
                    end
                end else if(!data_transfer_active && fd_sector_hdr_valid && fd_track == track && fd_sector == sector) begin
                    if (!cmd[5])
                        check_crc <= 1;
                    data_transfer_start <= 1'b1;
                end
            end

            // ------------------------ TYPE III -------------------------
            if(cmd_type_3) begin
                if(!fd_present) begin
                    // no image selected -> send irq immediately
                    RNF <= 1'b1;
                    ctl_busy <= 1'b0; 
                    irq_req <= 1'b1; // emit irq when command done
                end else begin
                    // read track
                    if(cmd[7:4] == 4'b1110) begin
                        // TODO (not used by 1571 rom)
                        ctl_busy <= 1'b0;
                        irq_req <= 1'b1; // emit irq when command done
                    end

                    // write track
                    if(cmd[7:4] == 4'b1111) begin
                        // TODO
                        ctl_busy <= 1'b0;
                        irq_req <= 1'b1; // emit irq when command done
                    end

                    // read address (used in 1571 rom)
                    if(cmd[7:4] == 4'b1100) begin
                        if((!cmd_rx && index_pulse_counter == 0) || data_transfer_done) begin
                            if (data_transfer_done)
                                address_update_strobe <= 1;
                            else
                                 RNF <= 1;

                            ctl_busy <= 1'b0;
                            irq_req <= 1'b1; // emit irq when command done
                        end else if(!data_transfer_active && fd_dclk_en && idam_detected) begin
                            check_crc <= 1'b1;
                            data_transfer_start <= 1'b1;
                        end
                    end
                end
            end
        end

        // stop motor if there was no command for 10 index pulses
        indexD <= fd_index;
        if(!indexD && fd_index) begin
            if(cmd_type_4 && cmd[2]) irq_req <= 1'b1;

            // let motor timeout run once fdc is not busy anymore
            if(!ctl_busy && motor_spin_up_done) begin
                if(motor_timeout_index != 0)
                    motor_timeout_index <= motor_timeout_index - 4'd1;
                else if(motor_on)
                    motor_timeout_index <= MOTOR_IDLE_COUNTER;

                if(motor_timeout_index == 1)
                    motor_on <= 1'b0;
            end

            if(motor_spin_up_sequence != 0)
                motor_spin_up_sequence <= motor_spin_up_sequence - 4'd1;

            if(ctl_busy && motor_spin_up_done && index_pulse_counter != 0)
                index_pulse_counter <= index_pulse_counter - 3'd1;
        end

        if(ctl_busy) 
            motor_timeout_index <= 0;
        else if(!cmd_rx)
            index_pulse_counter <= 0;
    end
end

// floppy delivers data at a floppy generated rate (usually 250kbit/s), so the start and stop
// signals need to be passed forth and back from cpu clock domain to floppy data clock domain
reg check_crc;
reg data_transfer_start;
reg data_transfer_done;

// Sync detector, byte aligner
 
reg  [15:0] shift_in_reg, shift_out_reg;
wire [15:0] shift_in = { shift_in_reg[14:0], hf };
reg   [3:0] shift_count;
reg         shift_out_enable;

assign      ht    = shift_out_reg[15];
assign      wgate = shift_out_enable;

wire sync_a1 = (shift_in == SYNC_A1_PATTERN);
wire sync_c2 = (shift_in == SYNC_C2_PATTERN);
wire sync    = (sync_a1 || sync_c2);

reg       aligned;
reg [7:0] aligned_data;
reg       aligned_sync_a1, aligned_sync_c2;

always @(posedge clkcpu)
begin
    if(!floppy_reset || clk8m_en)
        aligned <= 0;

    if(!floppy_reset || !fd_ready) begin
        shift_count      <= 4'd15;
        shift_out_reg    <= 0;
        shift_out_enable <= 0;
        aligned_data     <= 0;
        aligned_sync_a1  <= 0;
        aligned_sync_c2  <= 0;
        aligned          <= 0;
    end
    else if(hclk) begin
        if (write_out_strobe) begin
            shift_count      <= 4'd15;
            shift_out_reg    <= write_out;
            shift_out_enable <= 1;
        end 
        else if (shift_out_enable) begin
            shift_out_reg <= { shift_out_reg[14:0], 1'b0 };
            shift_count   <= shift_count - 4'd1;
            if (shift_count == 1) aligned <= 1;
            if (shift_count == 0) shift_out_enable <= 0;
        end	
        else begin
            shift_in_reg <= shift_in;
            shift_count  <= shift_count - 4'd1;

            if ((align_on_sync && sync) || !shift_count)
            begin
                shift_count     <= 4'd15;
                aligned_data    <= { shift_in[14], shift_in[12], shift_in[10], shift_in[8], shift_in[6], shift_in[4], shift_in[2], shift_in[0] };
                aligned_sync_a1 <= align_on_sync && sync_a1;
                aligned_sync_c2 <= align_on_sync && sync_c2;
                aligned         <= 1;
            end
        end
    end
end

// mark detector and header decoder

reg        data_mark;
reg  [1:0] sector_size_code;
reg        align_on_sync;
reg  [2:0] sync_detected;
reg [10:0] data_read_count; // including CRC bytes
reg  [7:0] data_out_read;
reg        fd_track_updated;
reg        crc_error_hdr, crc_error_data;
wire       crc_error = crc_error_data | crc_error_hdr;
reg        dam_detected, idam_detected;

function [10:0] sector_size;
    input [1:0] code;
    begin
        sector_size = {4'd1 << code, 7'd0};
    end
endfunction

function [15:0] crc;
    input [15:0] curcrc;
    input  [7:0] val;
    reg    [3:0] i;
    begin
        crc = {curcrc[15:8] ^ val, 8'h00};
        for (i = 0; i < 8; i=i+1'd1) begin
            if(crc[15]) begin
                crc = crc << 1;
                crc = crc ^ 16'h1021;
            end
            else crc = crc << 1;
        end
        crc = {curcrc[7:0] ^ crc[15:8], crc[7:0]};
    end
endfunction

always @(posedge clkcpu)
begin
    reg        last_sync_a1;
    reg        read_header, read_data;
    reg [15:0] crcchk;

    // if(clk8m_en) begin
    // 	fd_sector_hdr_start  <= 0;
    // end

    if(!floppy_reset || !fd_ready || cmd_rx) begin
        crc_error_data      <= 0;
        crc_error_hdr       <= 0;
        align_on_sync       <= 1;
        read_header         <= 0;
        read_data           <= 0;
        data_read_count     <= 0;
        fd_sector_hdr_valid <= 0;
         crcchk              <= 16'hFFFF;
        sync_detected       <= 0;
        idam_detected       <= 0;
        dam_detected        <= 0;
        // fd_sector_data_start <= 0;
    end
    else if(fd_dclk_en) begin
        // fd_sector_data_start <= 0;
        crcchk <= aligned_sync_a1 ? SYNC_A1_CRC : crc(crcchk, aligned_data);

        if (aligned_sync_a1 || aligned_sync_c2) begin
            last_sync_a1 <= aligned_sync_a1;
            if (aligned_sync_a1 != last_sync_a1)
                sync_detected <= 2'd1;
            else if (sync_detected < 4) 
                sync_detected <= sync_detected + 2'd1;

            read_header <= 0;
            read_data   <= 0;
            data_read_count  <= 0;
            fd_sector_hdr_valid <= 0;
        end
        else begin
            sync_detected <= 0;
            idam_detected <= 0;
            dam_detected  <= 0;

            if (sync_detected >= 3 && aligned_data[7:2] == 6'b1111_10) begin 
                // DDAM = F8/F9, DAM = FA/FB 
                data_mark    <= ~aligned_data[1];
                dam_detected <= 1;
                if (cmd[7:4] != 4'b1101)  // disable sync detection, unless we are reading a track
                    align_on_sync <= 0;
            end
            else if (sync_detected == 3 && aligned_data[7:2] == 6'b1111_11) begin
                // IDAM = FC..FF
                idam_detected <= 1;
                if (cmd[7:4] != 4'b1101)  // disable sync detection, unless we are reading a track
                    align_on_sync <= 0;
            end
            else if (idam_detected || read_header) begin
                data_out_read <= aligned_data;
                if (idam_detected) begin
                    fd_track        <= aligned_data;
                    data_read_count <= 11'd6;
                    read_header     <= 1;
                end
                else begin
                    data_read_count <= data_read_count - 11'd1;
                    case(data_read_count)
                        5: fd_sector        <= aligned_data;
                        4: sector_size_code <= aligned_data[1:0];
                    endcase
                end
                // header_byte <= 1;
            end
            else if (dam_detected || read_data) begin
                data_out_read <= aligned_data;
                if (dam_detected) begin
                    data_read_count <= sector_size(sector_size_code) + 11'd2;
                    read_data       <= 1;
                end
                else begin
                    data_read_count <= data_read_count - 11'd1;
                end
            end

            if (data_read_count == 1) begin
                read_data     <= 0;
                read_header   <= 0;
                align_on_sync <= 1;

                if (crcchk && check_crc) begin
                    if (read_data)   crc_error_data <= 1;
                    if (read_header) crc_error_hdr  <= 1;
                end

                if (!read_data && !crcchk)
                    fd_sector_hdr_valid <= 1;
            end
        end
    end
end

// -------------------- CPU data read/write -----------------------
reg        data_in_strobe, write_out_strobe;
reg [15:0] write_out;

typedef enum bit[3:0] {
    // transfer idle
    XF_IDLE,
    // read address 
    XF_RDAD,
    // read sector
    XF_RDSC, XF_RDSC_DATA,
    // write sector
    XF_WRSC, XF_WRSC_SYNC, XF_WRSC_DATA, XF_WRSC_CRC,
    // write track
    XF_WRTR, XF_WRTR_DATA, XF_WRTR_CRC
} xfer_state_t;

function [15:0] mfm_encode;
    input  [8:0] data;
    reg    [7:0] clock;
    begin
        clock = ~(data[8:1]|data[7:0]);
        mfm_encode = {
            clock[7], data[7],
            clock[6], data[6],
            clock[5], data[5],
            clock[4], data[4],
            clock[3], data[3],
            clock[2], data[2],
            clock[1], data[1],
            clock[0], data[0]
        };
    end
endfunction

xfer_state_t xfer_state = XF_IDLE;

wire data_transfer_active = xfer_state != XF_IDLE;

always @(posedge clkcpu) begin
    reg   [10:0] xfer_cnt;
    reg   [15:0] crccalc = 16'hFFFF;
    reg    [7:0] tmp_data;

    drq_set <= 1'b0;

    if (cpu_we && cpu_addr == FDC_REG_DATA)
        data_out <= data_in;

    if(!floppy_reset || !fd_ready || (cmd_rx && cmd_type_4)) begin
        xfer_cnt <= 0;
        xfer_state <= XF_IDLE;
        crccalc <= 16'hFFFF;
        write_out_strobe <= 0;
        data_transfer_done <= 0;
    end

    if (!floppy_reset || (cmd_rx && (cmd_type_1 || cmd_type_2 || cmd_type_3)))
        data_lost <= 0;

    if (clk8m_en) data_transfer_done <= 0;
    if (hclk) write_out_strobe <= 0;
    if (data_transfer_start) begin
        // read address
        if(cmd[7:4] == 4'b1100) begin
            xfer_state <= XF_RDAD;
            xfer_cnt <= 11'd6;
        end

        // read sector
        if(cmd[7:5] == 3'b100) begin
            xfer_state <= XF_RDSC;
            xfer_cnt <= 11'd43;
        end

        // todo read track

        // write sector
        if(cmd[7:5] == 3'b101) begin
            xfer_state <= XF_WRSC;
            xfer_cnt <= 11'd22;
        end

        // todo write track
    end

    if(fd_dclk_en) begin
        case(xfer_state)
            // read sector / read address

            XF_RDSC: begin
                // Read sector: wait for DAM, abort after 43 bytes or when another header was detected
                xfer_cnt <= xfer_cnt - 11'd1;
                if (!xfer_cnt) begin
                    xfer_state <= XF_IDLE;
                end else if (dam_detected) begin
                    xfer_state <= XF_RDSC_DATA;
                    xfer_cnt <= sector_size(sector_size_code);
                end
            end

            XF_RDAD,
            XF_RDSC_DATA: begin
                // Read sector & read address: transfer data to cpu
                if(xfer_cnt) begin
                    if(drq) 
                        data_lost <= 1;

                    drq_set <= 1;
                    data_out <= data_out_read;
                    xfer_cnt <= xfer_cnt - 11'd1;
                end else if (!data_read_count) begin
                    data_transfer_done <= 1'b1;
                    xfer_state <= XF_IDLE;
                end
            end

            // write sector

            XF_WRSC: begin
                // Write sector: delay 22 gap bytes
                if (xfer_cnt) begin
                    xfer_cnt <= xfer_cnt - 11'd1;
                    if(xfer_cnt == 20)
                        drq_set <= 1;

                    if(xfer_cnt == 11 && drq) begin
                        // abort when no data received from cpu
                        xfer_state <= XF_IDLE;
                        data_lost <= 1;
                        data_transfer_done <= 1;
                        xfer_cnt <= 0;
                    end
                end else begin
                    xfer_state <= XF_WRSC_SYNC;
                    xfer_cnt <= 11'd16;
                end
            end

            XF_WRSC_SYNC: begin
                // Write sector: write preamble and address mark (12 "00" bytes, 3 "A1" sync markers and 1 DAM or DDAM byte)
                if (xfer_cnt) begin
                    xfer_cnt <= xfer_cnt - 11'd1;
                    write_out_strobe <= 1;
                    write_out <= xfer_cnt > 3 ? mfm_encode(9'h000) : SYNC_A1_PATTERN;
                end else begin
                    tmp_data = cmd[0] ? 8'hF8 : 8'hFB;
                    write_out_strobe <= 1;
                    write_out <= mfm_encode({SYNC_A1_PATTERN[0], tmp_data});
                    crccalc <= crc(SYNC_A1_CRC, tmp_data);
                    xfer_state <= XF_WRSC_DATA;
                    xfer_cnt <= sector_size(sector_size_code);
                end
            end

            XF_WRSC_DATA: begin
                // Write sector: receive data from cpu and generate write signals
                xfer_cnt <= xfer_cnt - 11'd1;

                if (drq) 
                    data_lost <= 1;

                if (xfer_cnt > 1)
                    drq_set <= 1;

                tmp_data = drq ? 8'h00 : data_in;
                write_out_strobe <= 1;
                write_out <= mfm_encode({write_out[0], tmp_data});
                crccalc <= crc(crccalc, tmp_data);

                if(xfer_cnt == 1) begin
                    xfer_state <= XF_WRSC_CRC;
                    xfer_cnt <= 11'd3;
                end
            end

            XF_WRSC_CRC: begin
                // Write sector: write 2 CRC bytes, 1 trailing "FF" byte
                if (xfer_cnt) begin
                    xfer_cnt <= xfer_cnt - 11'd1;
                    crccalc <= {crccalc[7:0], 8'hFF};
                    write_out_strobe <= 1;
                    write_out <= mfm_encode({write_out[0], crccalc[15:8]});
                end else begin
                    xfer_state <= XF_IDLE;
                    data_transfer_done <= 1;
                end
            end
        endcase
    end
end

// reg data_lost, data_lost_set, data_lost_clr;
// always @(posedge clkcpu) begin
// 	if(data_lost_clr) data_lost <= 0;
// 	else if(data_lost_set) data_lost <= 1;
// end

wire [7:0] status = { (MODEL == 1 || MODEL == 3) ? !floppy_ready : motor_on,
              (cmd[7:5] == 3'b101 | cmd[7:4] == 4'b1111 | cmd_type_1) & fd_writeprot, // wrprot (only for write!)
              cmd_type_1?motor_spin_up_done:data_mark,    // data mark
              (crc_error&&!cmd_type_1)?crc_error_hdr:RNF, // seek error/record not found/crc error type
              crc_error,                                  // crc error
              (idle||cmd_type_1)?~fd_trk00:data_lost,     // track0/data lost
              (idle||cmd_type_1)?~fd_index:drq,           // index mark/drq
              cmd_busy } /* synthesis keep */;

reg [7:0] track /* verilator public */;
reg [7:0] sector;
reg [7:0] data_in;
reg [7:0] data_out;

reg step_dir;
reg motor_on /* verilator public */ = 1'b0;
reg data_lost = 0;

// ---------------------------- command register -----------------------   
reg [7:0] cmd /* verilator public */;
wire cmd_type_1 = (cmd[7] == 1'b0);
wire cmd_type_2 = (cmd[7:6] == 2'b10);
wire cmd_type_3 = (cmd[7:5] == 3'b111) || (cmd[7:4] == 4'b1100);
wire cmd_type_4 = (cmd[7:4] == 4'b1101);

localparam FDC_REG_CMDSTATUS    = 0;
localparam FDC_REG_TRACK        = 1;
localparam FDC_REG_SECTOR       = 2;
localparam FDC_REG_DATA         = 3;

// CPU register read
always @(*) begin
    cpu_dout = 8'h00;

    if(cpu_sel && cpu_rw) begin
        case(cpu_addr)
            FDC_REG_CMDSTATUS: cpu_dout = status;
            FDC_REG_TRACK:     cpu_dout = track;
            FDC_REG_SECTOR:    cpu_dout = sector;
            FDC_REG_DATA:      cpu_dout = data_out;
        endcase
    end
end

// cpu register write
reg cmd_rx;
reg cmd_rx_i;

always @(posedge clkcpu) begin
    if(!floppy_reset) begin
        cmd <= 8'h00;
        cmd_rx <= 0;
        cmd_rx_i <= 0;
        track <= 8'h00;
        sector <= 8'h00;
    end else begin
        // cmd_rx is delayed to make sure all signals (the cmd!) are stable when
        // cmd_rx is evaluated
        cmd_rx <= cmd_rx_i;

        // command reception is ack'd by fdc going busy
        if((!cmd_type_4 && ctl_busy) || (clk8m_en && cmd_type_4 && !ctl_busy)) cmd_rx_i <= 0;

        if(cpu_we) begin
            if(cpu_addr == FDC_REG_CMDSTATUS && (!cmd_busy || cpu_din[7:4] == 4'b1101)) begin          // command register
                cmd <= cpu_din;
                cmd_rx_i <= 1;

                // ------------- TYPE I commands -------------
                if(cpu_din[7:4] == 4'b0000) begin               // RESTORE
                    step_to <= 8'd0;
                    track <= 8'hff;
                end

                if(cpu_din[7:4] == 4'b0001) begin               // SEEK
                    step_to <= data_in;
                end
            end

            if(cpu_addr == FDC_REG_TRACK && !cmd_busy)                    // track register
                track <= cpu_din;

            if(cpu_addr == FDC_REG_SECTOR && !cmd_busy)                   // sector register
                sector <= cpu_din;

            if(cpu_addr == FDC_REG_DATA)                     // data register
                data_in <= cpu_din;
        end

        if (address_update_strobe) sector <= fd_track; // "read address" command updates *sector* register to current track
        if (sector_inc_strobe) sector <= sector + 1'd1;
        if (track_inc_strobe) track <= track + 1'd1;
        if (track_dec_strobe) track <= track - 1'd1;
        if (track_clear_strobe) track <= 8'd0;
    end
end

endmodule