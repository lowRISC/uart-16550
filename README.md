# UART 16550 Hardware IP Block

This repository contains a wrapper around [OpenTitan's well-verified UART hardware IP block][opentitan-uart] in order to support the common [16550 specification][16550-spec].

## Initial build

To do a test build you can use the following command:
```sh
fusesoc --cores-root=. run --target=lint lowrisc:ip:uart16550
```

To run the pre_dv tests, run the following command:
```sh
fusesoc --cores-root=. run --target=sim lowrisc:dv:uart16550_tb
```
A passing run will display `Test passed!`; a failing run will display `Test failed!`.

[opentitan-uart]: https://github.com/lowRISC/opentitan/tree/master/hw/ip/uart
[16550-spec]: https://web.archive.org/web/20180826215135/http://www.ti.com/lit/ds/symlink/pc16550d.pdf
