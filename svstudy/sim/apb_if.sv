// ============================================================
// File: apb_if.v
// Topic: APB-like interface / modport practice
// ============================================================
//
// Function:
//   Define a simplified APB-style bus interface.
//
// Practice goals:
//   1. Write a parameterized interface.
//   2. Use ADDR_WIDTH and DATA_WIDTH parameters.
//   3. Define master and slave modports.
//   4. Understand direction differences between bus master and bus slave.
//
// Required interface name:
//   apb_if
//
// Suggested parameters:
//   parameter int ADDR_WIDTH = 16
//   parameter int DATA_WIDTH = 32
//
// Signals:
//   psel    : transfer selected
//   penable : enable phase
//   pwrite  : 1 for write, 0 for read
//   paddr   : address
//   pwdata  : write data
//   prdata  : read data
//   pready  : slave ready
//   pslverr : slave error
//
// Master modport directions:
//   output psel
//   output penable
//   output pwrite
//   output paddr
//   output pwdata
//   input  prdata
//   input  pready
//   input  pslverr
//
// Slave modport directions:
//   input  psel
//   input  penable
//   input  pwrite
//   input  paddr
//   input  pwdata
//   output prdata
//   output pready
//   output pslverr
//
// Notes:
//   This is APB-like for practice. It does not need to cover every APB spec detail.
//
interface apb_if #(parameter int ADDR_WIDTH = 16, parameter int DATA_WIDTH = 32);
    logic psel;
    logic penable;
    logic pwrite;
    logic [ADDR_WIDTH-1 :0] paddr;
    logic [DATA_WIDTH-1 :0] pwdata;
    logic [DATA_WIDTH-1 :0] prdata;
    logic pready;
    logic pslverr;

    modport master (
        output psel,
        output penable,
        output pwrite,
        output paddr,
        output pwdata,
        input  prdata,
        input  pready,
        input  pslverr
    );
    
    modport slave (
        input  psel,
        input  penable,
        input  pwrite,
        input  paddr,
        input  pwdata,
        output prdata,
        output pready,
        output pslverr
    );

endinterface //apb_if