# k8scheck

## A K8S cluster integrity checker shell script. 

Author: Dragos Ruiu

Date: December 05 2023 v1.0

One of my pet peeves is huge ornate kubernetes cluster "scanners" and vuln and health checkers that include plug-ins, APIs,  AI comments, external integrations, client/server architectures, a few kitchen sinks and all kinds of frippery that can really just be replaced by a simple shell script and some kubectl commands.

Here is a shell script that will fit into in an extended tweet to do the all the same cluster consistency checks that other scanners do in their intricate code hairballs. Run this for some basic cluster integrity checks.

I'd suggest running this periodically (CronJob?), and diffing from the last report, then feeding it into ChatGPT for a summary. Examine the first run with humans.
