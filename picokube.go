package main

import (
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"syscall"

	"github.com/urfave/cli"
)

const initYml = `
applications:
  - name: kubernetes-dashboard
    namespace: kube-system
    workdir: dashboard
    nodedir: dashboard
    service: dashboard
    port: 80s
`

func writeFile(contents string, fileName string) {

	pwd, err := os.Getwd()
	check(err)
	//fmt.Println(pwd)

	//say(contents)
	//say(fileName)

	// ex, err := os.Executable()
	// if err != nil {
	// 	panic(err)
	// }
	// exPath := path.Dir(ex)
	fullFileName := fmt.Sprint(pwd, "/", fileName)
	err2 := ioutil.WriteFile(fullFileName, []byte(contents), 0644)
	check(err2)
}

func say(msg string) {
	fmt.Println(msg)
}

func check(e error) {
	if e != nil {
		panic(e)
	}
}

func runCmd(cmd []string) {

	binary, err := exec.LookPath(cmd[0])
	check(err)

	env := os.Environ()

	execErr := syscall.Exec(binary, cmd, env)
	check(execErr)
}

func main() {

	//runCmd([]string{"docker", "images"})

	runCmd([]string{"docker", "images"})

	cli.VersionFlag = cli.BoolFlag{
		Name:  "print-version, V",
		Usage: "print only the version",
	}

	app := cli.NewApp()
	app.Name = "cluster-compose"
	app.Version = ".1"
	app.Usage = "Instantly run and develop Kubernetes applications with just Docker"

	app.Flags = []cli.Flag{
		cli.StringFlag{
			Name:  "workdir, w",
			Value: "./",
			Usage: "Local work directory to mount inside the node. Defaults to current directory`",
		},
		cli.StringFlag{
			Name:  "nodedir, n",
			Value: "/workdir",
			Usage: "Work directory destination inside the node. Defaults to /nodedir`",
		},

		cli.StringFlag{
			Name:  "manifests, m",
			Usage: "Folder of manifests to apply when cluster has launched",
		},

		cli.StringFlag{
			Name:  "service, s",
			Usage: "Service to launch in browser at http://SERVICENAME.127.0.0.1.xip.io",
			Value: "dashboard.kube-system",
		},
	}

	app.Commands = []cli.Command{
		{
			Name:  "init",
			Usage: "generate an example cluster-compose.yaml",
			Action: func(c *cli.Context) error {

				writeFile(initYml, "cluster-compose.yml")
				say("write file?")
				return nil
			},
		},
		{
			Name:  "up",
			Usage: "launch cluster",
			Action: func(c *cli.Context) error {
				return nil
			},
		},
		{
			Name:  "down",
			Usage: "stop cluster",
			Action: func(c *cli.Context) error {
				return nil
			},
		},
		{
			Name:  "clean",
			Usage: "delete cluster",
			Action: func(c *cli.Context) error {
				return nil
			},
		},
	}

	app.Run(os.Args)
}
