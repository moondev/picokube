package main

import (
	"os"

	"github.com/urfave/cli"
)

func main() {

	cli.VersionFlag = cli.BoolFlag{
		Name:  "print-version, V",
		Usage: "print only the version",
	}

	app := cli.NewApp()
	app.Name = "picokube"
	app.Version = ".1"
	app.Usage = "Instantly run and develop Kubernetes applications with just Docker"

	app.Flags = []cli.Flag{
		cli.StringFlag{
			Name:  "workdir, w",
			Value: "./",
			Usage: "Local work directory to mount inside the node. Defaults to current directory`",
		},
		cli.StringFlag{
			Name:  "destination, d",
			Usage: "Work directory destinatin inside the node. Defaults to /workdir`",
		},

		cli.StringFlag{
			Name:  "manifests, m",
			Usage: "Folder of manifests to apply when cluster has launched",
		},

		cli.StringFlag{
			Name:  "init, i",
			Usage: "Initialize an example picokube.yaml",
		},
	}

	app.Commands = []cli.Command{
		{
			Name:    "complete",
			Aliases: []string{"c"},
			Usage:   "complete a task on the list",
			Action: func(c *cli.Context) error {
				return nil
			},
		},
		{
			Name:    "add",
			Aliases: []string{"a"},
			Usage:   "add a task to the list",
			Action: func(c *cli.Context) error {
				return nil
			},
		},
	}

	app.Run(os.Args)
}
