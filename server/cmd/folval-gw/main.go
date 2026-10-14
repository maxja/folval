// SPDX-License-Identifier: AGPL-3.0-or-later
// folval-gw — hermetic-lab mock gateway entrypoint (Phase 2).
package main

import (
	"fmt"
	"os"

	"github.com/maxja/folval/server/internal/config"
	"github.com/maxja/folval/server/internal/gateway"
)

func main() {
	if err := gateway.Run(config.ParseFlags()); err != nil {
		fmt.Fprintf(os.Stderr, "folval-gw: %v\n", err)
		os.Exit(1)
	}
}
