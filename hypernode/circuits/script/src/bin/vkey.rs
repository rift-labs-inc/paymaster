//! A script to print the program verification key.
//!
//! You can run this script using the following command:
//! ```shell
//! RUST_LOG=info cargo run --bin vkey --release
//! ```

use sp1_sdk::{HashableKey, ProverClient};

/// The ELF (executable and linkable format) file for the Succinct RISC-V zkVM.
///
/// This file is generated by running `cargo prove build` inside the `program` directory.
pub const MAIN_ELF: &[u8] = include_bytes!("../../../elf/riscv32im-succinct-zkvm-elf");

fn main() {
    // Setup the logger.
    sp1_sdk::utils::setup_logger();

    // Setup the prover client.
    let client = ProverClient::new();

    // Setup the program.
    let (_, vk) = client.setup(MAIN_ELF);

    // Print the verification key.
    println!("Program Verification Key: {}", vk.bytes32());
}
