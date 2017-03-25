package main

import (
	"io/ioutil"
	"os"
	"os/exec"
	"syscall"

	"github.com/urfave/cli"
)

func check(e error) {
	if e != nil {
		panic(e)
	}
}

// type SSHCommander struct {
// 	User string
// 	IP   string
// }

// func (s *SSHCommander) Command(cmd ...string) *exec.Cmd {
// 	arg := append(
// 		[]string{
// 			fmt.Sprintf("%s@%s", s.User, s.IP),
// 		},
// 		cmd...,
// 	)
// 	return exec.Command("ssh", arg...)
// }

func main() {
	// For our example we'll exec `ls`. Go requires an
	// absolute path to the binary we want to execute, so
	// we'll use `exec.LookPath` to find it (probably
	// `/bin/ls`).
	binary, lookErr := exec.LookPath("docker")
	if lookErr != nil {
		panic(lookErr)
	}

	// `Exec` requires arguments in slice form (as
	// apposed to one big string). We'll give `ls` a few
	// common arguments. Note that the first argument should
	// be the program name.
	args := []string{"docker", "images"}

	// `Exec` also needs a set of [environment variables](environment-variables)
	// to use. Here we just provide our current
	// environment.
	env := os.Environ()

	// Here's the actual `syscall.Exec` call. If this call is
	// successful, the execution of our process will end
	// here and be replaced by the `/bin/ls -a -l -h`
	// process. If there is an error we'll get a return
	// value.
	execErr := syscall.Exec(binary, args, env)
	if execErr != nil {
		panic(execErr)
	}

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

				const out = `
applications:
  - name: kubernetes-dashboard
    namespace: kube-system
    workdir: dashboard
    nodedir: dashboard
    service: dashboard
    port: 80s
`

				err := ioutil.WriteFile("cluster-compose.yml", []byte(out), 0644)
				check(err)

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
