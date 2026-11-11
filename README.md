# UART 16550 Hardware IP Repository

This repository contains a wrapper around [OpenTitan's well-verified UART hardware IP block][opentitan-uart] in order to support the common [16550 specification][16550-spec].

> [!IMPORTANT]
> The design for this IP is incomplete and the RTL will change significantly. This IP is also not well verified.

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

## Contributing

Feel free to open issues if you have any questions or would like to contribute.
We recommend opening an issue to discuss a contribution before preparing a pull request.

## License

Unless otherwise noted, everything in this repository is covered by the Apache License, Version 2.0 (see [LICENSE](https://github.com/lowRISC/uart-16550/blob/main/LICENSE) for full text).
