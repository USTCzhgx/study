// ============================================================
// File: stream_if.v
// Topic: SystemVerilog interface / modport practice
// ============================================================
//
// Function:
//   Define a simple valid-ready stream interface.
//
// Signals:
//   valid : source side asserts when data is valid
//   ready : sink side asserts when it can accept data
//   data  : payload transferred when valid && ready is true
//
// Practice goals:
//   1. Write a parameterized interface.
//   2. Use DATA_WIDTH as the data bus width parameter.
//   3. Declare valid, ready, and data inside the interface.
//   4. Define two modports:
//        master:
//          output valid
//          output data
//          input  ready
//        slave:
//          input  valid
//          input  data
//          output ready
//
// Requirements:
//   1. The interface name should be stream_if.
//   2. DATA_WIDTH should default to 32.
//   3. This file should only contain the interface definition.
//
// Notes:
//   interface defines a bundle of related signals.
//   modport defines the direction of those signals from a module's view.
//
