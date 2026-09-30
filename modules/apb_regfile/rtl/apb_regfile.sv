// -----------------------------------------------------------------------------
// apb_regfile — APB4 slave with a small control/status register block.
//
//   offset  name        access  description
//   0x00    ID          RO      ID_VALUE parameter
//   0x04    CTRL        RW      drives ctrl_o
//   0x08    STATUS      RO      live value of status_i
//   0x0C    IRQ_STATUS  W1C     bit k set by irq_event_i[k]; write 1 to clear
//   0x10    IRQ_ENABLE  RW      irq_o = |(IRQ_STATUS & IRQ_ENABLE)
//   0x14    SCRATCH     RW      no side effects
//
// * Zero wait states (pready_o = 1), pstrb byte enables on writes.
// * pslverr_o for unmapped or misaligned addresses and for writes to RO
//   registers; such writes have no effect, erroneous reads return 0.
// * If an event and a W1C clear hit the same bit in one cycle, the event wins.
// -----------------------------------------------------------------------------
module apb_regfile #(
  parameter logic [31:0] ID_VALUE = 32'h4150_4201,
  parameter int unsigned NIRQ     = 8
) (
  input  logic            pclk_i,
  input  logic            presetn_i,

  input  logic            psel_i,
  input  logic            penable_i,
  input  logic            pwrite_i,
  input  logic [7:0]      paddr_i,
  input  logic [31:0]     pwdata_i,
  input  logic [3:0]      pstrb_i,
  output logic [31:0]     prdata_o,
  output logic            pready_o,
  output logic            pslverr_o,

  output logic [31:0]     ctrl_o,
  input  logic [31:0]     status_i,
  input  logic [NIRQ-1:0] irq_event_i,
  output logic            irq_o
);

  localparam logic [7:0] A_ID      = 8'h00;
  localparam logic [7:0] A_CTRL    = 8'h04;
  localparam logic [7:0] A_STATUS  = 8'h08;
  localparam logic [7:0] A_IRQ_ST  = 8'h0C;
  localparam logic [7:0] A_IRQ_EN  = 8'h10;
  localparam logic [7:0] A_SCRATCH = 8'h14;

  logic [31:0]     ctrl_q, scratch_q;
  logic [NIRQ-1:0] irq_st_q, irq_en_q;
  logic [31:0]     wmask, rdata;
  logic            access, wr, mapped, ro, err;

  assign access = psel_i && penable_i;
  assign wmask  = {{8{pstrb_i[3]}}, {8{pstrb_i[2]}}, {8{pstrb_i[1]}}, {8{pstrb_i[0]}}};

  // Address decode.
  always_comb begin
    mapped = 1'b1;
    ro     = 1'b0;
    rdata  = '0;
    unique case (paddr_i)
      A_ID:      begin rdata = ID_VALUE; ro = 1'b1; end
      A_CTRL:    rdata = ctrl_q;
      A_STATUS:  begin rdata = status_i; ro = 1'b1; end
      A_IRQ_ST:  rdata = 32'(irq_st_q);
      A_IRQ_EN:  rdata = 32'(irq_en_q);
      A_SCRATCH: rdata = scratch_q;
      default:   mapped = 1'b0;     // also catches misaligned offsets
    endcase
  end

  assign err       = !mapped || (pwrite_i && ro);
  assign wr        = access && pwrite_i && !err;
  assign pready_o  = 1'b1;
  assign pslverr_o = access && err;
  assign prdata_o  = (access && !pwrite_i && !err) ? rdata : '0;

  always_ff @(posedge pclk_i or negedge presetn_i) begin
    if (!presetn_i) begin
      ctrl_q    <= '0;
      scratch_q <= '0;
      irq_en_q  <= '0;
      irq_st_q  <= '0;
    end else begin
      if (wr && paddr_i == A_CTRL)    ctrl_q    <= (ctrl_q & ~wmask) | (pwdata_i & wmask);
      if (wr && paddr_i == A_SCRATCH) scratch_q <= (scratch_q & ~wmask) | (pwdata_i & wmask);
      if (wr && paddr_i == A_IRQ_EN)
        irq_en_q <= (irq_en_q & ~wmask[NIRQ-1:0]) | (pwdata_i[NIRQ-1:0] & wmask[NIRQ-1:0]);
      irq_st_q <= (irq_st_q & ~((wr && paddr_i == A_IRQ_ST) ? pwdata_i[NIRQ-1:0] & wmask[NIRQ-1:0]
                                                            : '0))
                  | irq_event_i;
    end
  end

  assign ctrl_o = ctrl_q;
  assign irq_o  = |(irq_st_q & irq_en_q);

`ifndef SYNTHESIS
  initial assert (NIRQ >= 1 && NIRQ <= 32) else $fatal(1, "apb_regfile: NIRQ must be 1..32");

  a_err_in_access: assert property (@(posedge pclk_i) disable iff (!presetn_i)
                                    pslverr_o |-> access);
  // Every event is visible in IRQ_STATUS on the next cycle (set beats clear).
  a_event_sets: assert property (@(posedge pclk_i) disable iff (!presetn_i)
                                 (irq_st_q & $past(irq_event_i)) == $past(irq_event_i));
`endif

endmodule
