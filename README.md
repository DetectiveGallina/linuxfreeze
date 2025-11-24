## LINUXFREEZE

Un script de bash para congelar usaurios en liunx, como Ofris pero actual y con mejoras. Posee soporte para systemD, OpenRC y SysVinit.

Funciona restaurando la carpeta home de cada usuario congelado en el arranque, eliminando cualquier modificación por el mismo. Simplemente ejecuta el script estableciendo una contraseña con *`set-password`* y luego congela un usuario con *`freeze <nombre de usuario>`*.

Esto creará un backup y un script de restaración para ese usaurio que lo restablezca al estado actual de su carpeta home. Además se le quitan todos los permisos de uso de sudo, por lo que es incapaz de eliminar tanto el script de congelado como de instalar software no deseado por el que administrador. 

Si se desea instalar, eliminar o actualizar el software simplemente deberá logearse como root o como otro usuario que tenga permisos de sudo y ejecutar los comandos pertinentes para su distribución.
