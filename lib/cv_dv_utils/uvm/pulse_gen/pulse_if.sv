// ----------------------------------------------------------------------------
//Copyright 2023 CEA*
//*Commissariat a l'Energie Atomique et aux Energies Alternatives (CEA)
//
//Licensed under the Apache License, Version 2.0 (the "License");
//you may not use this file except in compliance with the License.
//You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//Unless required by applicable law or agreed to in writing, software
//distributed under the License is distributed on an "AS IS" BASIS,
//WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//See the License for the specific language governing permissions and
//limitations under the License.
//[END OF HEADER]
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
//  Description : Puls gen interface.
//
//
// ----------------------------------------------------------------------------

interface pulse_if ( input bit clk, input bit rstn );

timeunit 1ns;
timeprecision 1ps;


   // generated output pulse 
   logic m_pulse_out; 
   
   
   // ------------------------------------------------------------------------
   // Delay Task 
   // ------------------------------------------------------------------------
   task automatic wait_n_clocks( int N );         
   begin
       @( posedge clk );
       repeat (N-1) @( posedge clk );
   end
   endtask : wait_n_clocks

endinterface : pulse_if
